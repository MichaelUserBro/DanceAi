import 'dart:async';
import 'dart:io';

import '../data/app_data.dart';
import '../data/criteria.dart';
import '../data/providers_catalog.dart';
import '../report/report.dart';
import '../report/report_validator.dart';
import 'ai_provider.dart';
import 'analysis_failure.dart';
import 'cancel_token.dart';
import 'prompt_builder.dart';
import 'temp_storage.dart';
import 'video_preparer.dart';

/// Потолок на весь анализ вместе с повтором (spec 7.7). Меняется здесь.
const Duration analysisTimeLimit = Duration(minutes: 5);

/// Повтор после невалидного ответа запускается, только если до потолка
/// остаётся не меньше этого (и не меньше, чем занял первый запрос).
const Duration minRetryTime = Duration(seconds: 60);

/// Новая попытка после перегрузки или смены модели начинается, только если
/// до потолка остаётся не меньше этого (плюс пауза перед ней).
const Duration minAttemptTime = Duration(seconds: 60);

/// 503 пришёл дольше этого — ту же модель не повторяем, сразу запасная.
const Duration slowOverloadThreshold = Duration(seconds: 30);

/// Предел ожидания начала ответа — от конца отправки (spec 7.7). Действует,
/// только если адаптер отвечает потоком и в цепочке есть следующая модель.
/// По живым проверкам ответ начинался не позже 127 с после отправки.
const Duration responseStartLimit = Duration(seconds: 150);

/// Предел срабатывает не позже момента, когда до потолка остаётся столько —
/// время на следующую модель цепочки.
const Duration fallbackReserve = Duration(seconds: 110);

/// Паузы перед повтором после перегрузки — растут по ходу анализа.
const List<Duration> overloadPauses = [
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 15),
];

/// «5 минут» — для строк интерфейса.
String get analysisTimeLimitRu => '${analysisTimeLimit.inMinutes} минут';

/// Этапы экрана анализа (spec 8б.3).
enum AnalysisStage {
  checkingVideo('Проверка видео'),
  compressingVideo('Сжатие видео'),
  extractingFrames('Кадры'),
  analyzingMusic('Музыка'),
  sending('Отправка'),
  processing('Обработка видео у провайдера'),
  analyzing('Анализ'),
  validating('Проверка ответа');

  const AnalysisStage(this.labelRu);
  final String labelRu;
}

/// Почему начата попытка (для «Для разработчика» и строк экрана анализа).
enum AttemptReason {
  /// Первый запрос.
  first,

  /// Прошлый ответ не прошёл проверку — исправляющий запрос.
  invalidResponse,

  /// Сервер перегружен (503) — повтор той же модели или запасная.
  overloaded,

  /// Квота модели исчерпана (429) — запасная модель.
  rateLimit,

  /// Запасная модель недоступна (404 и т. п.) — следующая.
  modelUnavailable,

  /// Модель не начала отвечать (предел ожидания или обрыв до заголовков) —
  /// следующая.
  noResponse,
}

/// Что показать на экране анализа о повторе или смене модели.
class AttemptNotice {
  const AttemptNotice({required this.reason, required this.model, this.nextModel});

  final AttemptReason reason;

  /// Модель, с которой случилась неудача.
  final String model;

  /// Запасная модель (null — повтор той же).
  final String? nextModel;
}

class AnalysisProgress {
  const AnalysisProgress(this.stage,
      {this.fraction, this.isRetry = false, this.receivedBytes, this.notice});

  /// Повтор или переход на запасную модель (null — ничего нового).
  final AttemptNotice? notice;

  final AnalysisStage stage;
  final double? fraction;

  /// Получено байт ответа (потоковая отдача) — живой прогресс «Анализ».
  final int? receivedBytes;

  /// Идёт повторный запрос после неудачной проверки ответа.
  final bool isRetry;
}

/// Один запрос к ИИ (первый или повторный) — для «Для разработчика».
class AiAttempt {
  AiAttempt(
      {required this.retry,
      this.model,
      this.reason = AttemptReason.first,
      this.pause = Duration.zero});

  final bool retry;

  /// Модель этой попытки (основная или запасная).
  final String? model;

  /// Почему попытка начата.
  final AttemptReason reason;

  /// Пауза перед попыткой.
  final Duration pause;

  /// HTTP-статус, время заголовков и первого байта, источник ошибки.
  HttpDiag? diag;

  /// До конца отправки и до ответа (от начала запроса).
  Duration? sendTime;
  Duration? totalTime;
  int? sentBytes;
  AiUsage? usage;
  String? finishReason;
  List<String> notes = const [];

  /// Ошибка API (без ключа).
  String? error;

  Map<String, Object?> toJson() => {
        'retry': retry,
        'model': model,
        'reason': reason.name,
        'pause_ms': pause.inMilliseconds,
        'http_status': diag?.status,
        'headers_ms': diag?.headersTime?.inMilliseconds,
        'first_byte_ms': diag?.firstByteTime?.inMilliseconds,
        'error_source': diag?.errorSource?.name,
        'send_ms': sendTime?.inMilliseconds,
        'total_ms': totalTime?.inMilliseconds,
        'sent_bytes': sentBytes,
        'usage': usage?.toJson(),
        'finish_reason': finishReason,
        'notes': notes,
        'error': error,
      };
}

/// Что видно в разделе «Для разработчика» о последнем анализе.
/// Только в памяти; ключа здесь нет.
class AnalysisTrace {
  BuiltPrompt? prompt;
  SubmissionMode? mode;
  String? musicAnalysis;
  double? durationSec;
  int? frameCount;
  String? danceId;

  /// Провайдер и модель (имя из каталога, не ключ). [model] — запрошенная
  /// (из настроек), [answeredModel] — фактически ответившая.
  String? providerName;
  String? model;
  String? answeredModel;
  bool demo = false;

  /// Настройка «Использовать запасные модели» и цепочка моделей этого
  /// анализа (первая — модель пользователя).
  bool? useFallbackModels;
  List<String> modelChain = const [];

  /// Частота, с которой модель смотрит видео (если API это позволяет).
  double? videoFps;

  /// Уровень размышления (если API позволяет); null — по умолчанию модели.
  String? thinkingLevel;

  /// «Максимум кадров» из настроек провайдера; null — по умолчанию адаптера.
  int? maxFramesSetting;
  DateTime? startedAt;
  Duration? totalTime;
  final List<AiAttempt> attempts = [];

  /// Итоговый отчёт (как его вернула модель, после проверки).
  Map<String, dynamic>? reportJson;

  /// Почему анализ не удался (вид ошибки и подробности без ключа).
  String? failure;

  /// Подготовка видео: сведения, превью кадров, время стадий (spec 7.8).
  final PrepareDiagnostics prepare = PrepareDiagnostics();
  final List<String> responses = [];
  final List<List<String>> problems = [];

  bool get retried => attempts.length > 1;
}

class AnalysisResult {
  const AnalysisResult(
      {required this.report,
      required this.retried,
      this.requestedModel,
      this.answeredModel});

  final DanceReport report;
  final bool retried;
  final String? requestedModel;
  final String? answeredModel;

  /// Отчёт подготовила запасная модель (основная была перегружена).
  String? get fallbackModel =>
      answeredModel != null && answeredModel != requestedModel
          ? answeredModel
          : null;
}

/// Подготовка → промпт → провайдер → проверка (+ один повтор).
/// Временная папка анализа удаляется в любом исходе.
class AnalysisPipeline {
  AnalysisPipeline({
    required this.data,
    required this.preparer,
    required this.provider,
    required this.tempStorage,
    this.demo = false,
    this.timeLimit = analysisTimeLimit,
    this.fallbackModels = const [],
    this.providerFor,
    this.useFallbackModels,
    this.overloadHintRu,
    this.slowOverload = slowOverloadThreshold,
    this.startLimit = responseStartLimit,
    this.startReserve = fallbackReserve,
    Future<void> Function(Duration, CancelToken)? pause,
  })  : _pause = pause ?? _cancellableDelay,
        _validator = ReportValidator(data.criteria),
        _prompts = PromptBuilder(data);

  final AppData data;
  final VideoPreparer preparer;
  final AiProvider provider;
  final TempStorage tempStorage;

  /// Анализ идёт через заглушку («Демо-режим»).
  final bool demo;

  /// Потолок на весь анализ (в тестах — короче).
  final Duration timeLimit;

  /// Запасные модели провайдера (пусто — настройка выключена или их нет).
  final List<FallbackModel> fallbackModels;

  /// Адаптер того же провайдера для другой модели (запасной).
  final AiProvider Function(String model)? providerFor;

  /// Состояние настройки «Использовать запасные модели» (для JSON).
  final bool? useFallbackModels;

  /// Подсказка провайдера к ошибке «Сервер ИИ перегружен».
  final String? overloadHintRu;

  /// Порог «медленного» 503 (в тестах — другой).
  final Duration slowOverload;

  /// Предел ожидания начала ответа и резерв на следующую модель (в тестах —
  /// другие).
  final Duration startLimit;
  final Duration startReserve;

  final Future<void> Function(Duration, CancelToken) _pause;

  static Future<void> _cancellableDelay(Duration d, CancelToken c) async {
    await Future.any([Future<void>.delayed(d), c.whenCancelled]);
    c.throwIfCancelled();
  }
  final ReportValidator _validator;
  final PromptBuilder _prompts;

  /// [wantVideo] — в настройках включено «Модель принимает видео со звуком».
  /// [forceFrames] — «Отправить кадрами» после ошибки режима видео.
  /// [videoFps] — с какой частотой модель смотрит видео (где API позволяет).
  Future<AnalysisResult> run({
    required Dance dance,
    required String videoPath,
    required bool wantVideo,
    required CancelToken cancel,
    required void Function(AnalysisProgress) onProgress,
    AnalysisTrace? trace,
    bool forceFrames = false,
    double videoFps = 2,
    String? thinkingLevel,
    int? maxFrames,
  }) async {
    final caps = provider.capabilities;
    final frameOptions = maxFrames == null
        ? caps.frameOptions
        : FrameOptions(
            fps: caps.frameOptions.fps,
            maxFrames: maxFrames,
            maxLongSidePx: caps.frameOptions.maxLongSidePx,
          );
    final thinking = caps.thinkingConfigurable ? thinkingLevel : null;
    final mode = wantVideo && caps.supportsVideo && !forceFrames
        ? SubmissionMode.video
        : SubmissionMode.frames;
    final total = Stopwatch()..start();
    trace
      ?..providerName = provider.displayName
      ..model = provider.model
      ..demo = demo
      ..danceId = dance.id
      ..mode = mode
      ..startedAt = DateTime.now()
      ..videoFps = mode == SubmissionMode.video && caps.videoFpsConfigurable
          ? videoFps
          : null
      ..thinkingLevel = thinking
      ..maxFramesSetting = maxFrames
      ..useFallbackModels = useFallbackModels;
    Directory? workDir;
    try {
      workDir = await tempStorage.createWorkDir();
      cancel.throwIfCancelled();

      final PreparedMaterial material;
      try {
        material = await preparer.prepare(
          PrepareRequest(
            videoPath: videoPath,
            dance: dance,
            mode: mode,
            frameOptions: frameOptions,
            workDir: workDir,
            diagnostics: trace?.prepare,
          ),
          onProgress: (p) => onProgress(AnalysisProgress(
            switch (p.stage) {
              PrepareStage.checkingVideo => AnalysisStage.checkingVideo,
              PrepareStage.compressingVideo => AnalysisStage.compressingVideo,
              PrepareStage.extractingFrames => AnalysisStage.extractingFrames,
              PrepareStage.analyzingMusic => AnalysisStage.analyzingMusic,
            },
            fraction: p.fraction,
          )),
          cancel: cancel,
        );
      } on PrepareException catch (e) {
        throw AnalysisFailure.fromPrepare(e);
      }
      cancel.throwIfCancelled();

      // Облегчённая копия больше, чем может отправить адаптер.
      final maxVideo = caps.maxVideoBytes;
      final videoBytes = material.video?.sizeBytes;
      if (mode == SubmissionMode.video &&
          maxVideo != null &&
          videoBytes != null &&
          videoBytes > maxVideo) {
        throw AnalysisFailure(FailureKind.videoTooLarge, details: [
          'облегчённая копия $videoBytes байт > лимит адаптера $maxVideo',
        ]);
      }

      final prompt =
          _prompts.build(dance: dance, mode: mode, material: material);
      trace
        ?..prompt = prompt
        ..musicAnalysis = material.musicAnalysis
        ..durationSec = material.durationSec
        ..frameCount = material.frames.length;

      var request = AiRequest(
        danceId: dance.id,
        systemPrompt: prompt.system,
        userPrompt: prompt.user,
        mode: mode,
        material: material,
        reportSchema: data.reportSchema,
        videoFps: videoFps,
        thinkingLevel: thinking,
      );

      // Цепочка моделей: модель пользователя, затем запасные, принимающие
      // этот способ подачи (spec 7.7).
      final chain = <String>[provider.model];
      final framesOnly = <String>[];
      if (providerFor != null) {
        for (final f in fallbackModels) {
          if (chain.contains(f.id) || f.id.trim().isEmpty) continue;
          if (f.modes.contains(mode.name)) {
            chain.add(f.id);
          } else if (mode == SubmissionMode.video &&
              f.modes.contains(SubmissionMode.frames.name)) {
            framesOnly.add(f.id);
          }
        }
      }
      trace?.modelChain = List.unmodifiable(chain);

      final base = request;
      var current = provider;
      var modelIndex = 0;
      var sameModelRetried = false;
      var correctionUsed = false;
      var pauseIndex = 0;
      var nextPause = Duration.zero;
      var nextReason = AttemptReason.first;
      Duration? lastAnswerTime;
      AiException? lastError;
      var sawOverload = false;

      // Повторы и запасные исчерпаны (или на них нет времени).
      AnalysisFailure exhausted(String why) {
        final video = mode == SubmissionMode.video;
        if (sawOverload || lastError == null) {
          return AnalysisFailure(FailureKind.overloaded,
              details: [why, ?lastError?.detail],
              hintRu: overloadHintRu,
              videoMode: video,
              framesFallback: video && framesOnly.isNotEmpty);
        }
        final f = AnalysisFailure.fromAi(lastError, videoMode: video);
        return f.withDetails([why, ...f.details]);
      }

      while (true) {
        final isRetry = nextReason == AttemptReason.invalidResponse;
        var remaining = timeLimit - total.elapsed;
        if (nextReason == AttemptReason.invalidResponse) {
          // Исправляющий повтор — только если на него остаётся разумное время.
          final t = lastAnswerTime;
          final need = t != null && t > minRetryTime ? t : minRetryTime;
          if (remaining < need) {
            throw AnalysisFailure(FailureKind.timeLimit, details: [
              'первый ответ не прошёл проверку, на повтор не хватает времени '
                  '(осталось ${remaining.inSeconds} с)',
            ]);
          }
        } else if (nextReason != AttemptReason.first &&
            remaining < minAttemptTime + nextPause) {
          throw exhausted('на следующую попытку не хватает времени '
              '(осталось ${remaining.inSeconds} с)');
        }
        if (remaining <= Duration.zero) {
          throw const AnalysisFailure(FailureKind.timeLimit,
              details: ['потолок исчерпан на подготовке']);
        }
        if (nextPause > Duration.zero) {
          await _pause(nextPause, cancel);
          remaining = timeLimit - total.elapsed;
        }
        onProgress(AnalysisProgress(AnalysisStage.sending, isRetry: isRetry));
        final record = AiAttempt(
            retry: nextReason != AttemptReason.first,
            model: current.model,
            reason: nextReason,
            pause: nextPause);
        trace?.attempts.add(record);
        final sw = Stopwatch()..start();
        // Своя отмена запроса: пользователь или потолок времени.
        final attemptCancel = CancelToken();
        var timedOut = false;
        final userSub =
            cancel.whenCancelled.then((_) => attemptCancel.cancel());
        final timer = Timer(remaining, () {
          timedOut = true;
          attemptCancel.cancel();
        });
        // Предел ожидания начала ответа (spec 7.7): адаптер отвечает потоком
        // и есть следующая модель. Отсчёт — с конца отправки; срабатывает не
        // позже, чем до потолка останется резерв на следующую модель.
        final limitStart = current.capabilities.streamsResponse &&
            modelIndex + 1 < chain.length;
        Timer? startTimer;
        var answerStarted = false;
        Duration? noResponseAfter;
        void watchStart(AiProgress p) {
          if (!limitStart) return;
          if (p.phase == AiPhase.sending) {
            // Новый HTTP-запрос (в т. ч. повтор адаптера без параметра).
            startTimer?.cancel();
            startTimer = null;
            answerStarted = false;
          } else if (p.phase == AiPhase.waiting) {
            if (p.receivedBytes != null) {
              answerStarted = true;
              startTimer?.cancel();
              startTimer = null;
            } else if (!answerStarted && startTimer == null) {
              final toReserve = timeLimit - startReserve - total.elapsed;
              final wait = toReserve < startLimit ? toReserve : startLimit;
              // Резерва уже нет — прерывать незачем, ждём до конца.
              if (wait <= Duration.zero) return;
              startTimer = Timer(wait, () {
                noResponseAfter = wait;
                attemptCancel.cancel();
              });
            }
          }
        }

        var raw = '';
        AiException? failed;
        try {
          final response = await current.analyze(
            request,
            onProgress: (p) {
              watchStart(p);
              if (p.phase != AiPhase.sending) record.sendTime ??= sw.elapsed;
              onProgress(AnalysisProgress(
                switch (p.phase) {
                  AiPhase.sending => AnalysisStage.sending,
                  AiPhase.processing => AnalysisStage.processing,
                  AiPhase.waiting => AnalysisStage.analyzing,
                },
                fraction: p.phase == AiPhase.sending ? p.fraction : null,
                receivedBytes: p.receivedBytes,
                isRetry: isRetry,
              ));
            },
            cancel: attemptCancel,
          );
          raw = response.text;
          record
            ..totalTime = sw.elapsed
            ..sentBytes = response.sentBytes
            ..usage = response.usage
            ..finishReason = response.finishReason
            ..notes = response.notes
            ..diag = response.diag;
        } on AiException catch (e) {
          record
            ..totalTime = sw.elapsed
            ..sentBytes = e.sentBytes
            ..notes = e.notes
            ..diag = e.diag
            ..error =
                '${e.kind.name}${e.detail == null ? '' : ': ${e.detail}'}';
          failed = e;
        } on AnalysisCancelled {
          record.totalTime = sw.elapsed;
          if (timedOut && !cancel.isCancelled) {
            record.error = 'timeLimit';
            throw AnalysisFailure(FailureKind.timeLimit, details: [
              'ответ не пришёл до потолка ${timeLimit.inSeconds} с',
            ]);
          }
          final after = noResponseAfter;
          if (after == null || cancel.isCancelled) rethrow;
          final why = 'нет ответа за ${after.inSeconds} с после отправки — '
              'прервано, следующая модель';
          record
            ..notes = [why]
            ..error = 'noResponse: $why';
          failed = AiException(AiErrorKind.noResponse, why);
        } finally {
          timer.cancel();
          startTimer?.cancel();
          unawaited(userSub);
        }
        cancel.throwIfCancelled();

        if (failed != null) {
          final e = failed;
          lastError = e;
          final AttemptReason reason;
          switch (e.kind) {
            case AiErrorKind.overloaded:
              sawOverload = true;
              reason = AttemptReason.overloaded;
              // Быстрый 503 — один повтор той же модели после паузы.
              if (!sameModelRetried && sw.elapsed < slowOverload) {
                sameModelRetried = true;
                nextPause = overloadPauses[pauseIndex < overloadPauses.length
                    ? pauseIndex
                    : overloadPauses.length - 1];
                pauseIndex++;
                nextReason = reason;
                onProgress(AnalysisProgress(AnalysisStage.sending,
                    notice: AttemptNotice(reason: reason, model: current.model)));
                continue;
              }
            case AiErrorKind.noResponse:
              // Как медленный 503: ту же модель не повторяем.
              sawOverload = true;
              reason = AttemptReason.noResponse;
            case AiErrorKind.rateLimit:
              reason = AttemptReason.rateLimit;
            case AiErrorKind.modelUnavailable when modelIndex > 0:
              reason = AttemptReason.modelUnavailable;
            default:
              // Ключ, сеть, размер, фильтры, модель пользователя — без цепочки.
              throw AnalysisFailure.fromAi(e,
                  videoMode: mode == SubmissionMode.video);
          }
          if (modelIndex + 1 >= chain.length) {
            throw exhausted(chain.length > 1
                ? 'все модели цепочки перегружены или недоступны'
                : e.kind == AiErrorKind.noResponse
                    ? 'сервер не начал отвечать'
                    : 'повторы не помогли');
          }
          final failedModel = current.model;
          modelIndex++;
          current = providerFor!(chain[modelIndex]);
          sameModelRetried = false;
          request = base;
          nextPause = Duration.zero;
          nextReason = reason;
          onProgress(AnalysisProgress(AnalysisStage.sending,
              notice: AttemptNotice(
                  reason: reason, model: failedModel, nextModel: current.model)));
          continue;
        }

        lastAnswerTime = sw.elapsed;
        trace?.responses.add(raw);

        onProgress(AnalysisProgress(AnalysisStage.validating, isRetry: isRetry));
        final outcome = parseReport(raw, dance: dance, validator: _validator);
        switch (outcome) {
          case ParsedReport(:final report, :final json):
            trace
              ?..reportJson = json
              ..answeredModel = current.model;
            return AnalysisResult(
                report: report,
                retried: trace == null ? isRetry : trace.retried,
                requestedModel: provider.model,
                answeredModel: current.model);
          case InvalidReport(:final problems):
            trace?.problems.add(problems);
            if (correctionUsed) {
              throw AnalysisFailure(FailureKind.invalidResponse,
                  details: problems);
            }
            correctionUsed = true;
            request = request.retry(
              note: _prompts.retryNote(problems),
              previous: raw,
            );
            nextPause = Duration.zero;
            nextReason = AttemptReason.invalidResponse;
            onProgress(AnalysisProgress(AnalysisStage.sending,
                isRetry: true,
                notice: AttemptNotice(
                    reason: AttemptReason.invalidResponse,
                    model: current.model)));
        }
      }
    } on AnalysisFailure catch (f) {
      trace?.failure = [f.kind.name, ...f.details.take(5)].join(': ');
      rethrow;
    } on AnalysisCancelled {
      trace?.failure = 'cancelled';
      rethrow;
    } catch (e) {
      // Неожиданная ошибка: без текста исключения в интерфейсе.
      trace?.failure = 'internal: ${e.runtimeType}';
      throw AnalysisFailure(FailureKind.internal,
          details: [e.runtimeType.toString()]);
    } finally {
      trace?.totalTime = total.elapsed;
      if (workDir != null) await tempStorage.deleteDir(workDir);
    }
  }
}
