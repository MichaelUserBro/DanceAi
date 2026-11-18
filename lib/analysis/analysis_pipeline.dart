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

/// Потолок на обращение к ИИ — от загрузки материала или первого запроса,
/// вместе со всеми повторами и запасными моделями (spec 7.7). Проверка
/// видео, сжатие и анализ музыки в него не входят. Меняется здесь.
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

/// Ожидаемое время ответа модели, если в providers.json (`expected_sec`)
/// нет данных.
const Duration defaultExpectedFrames = Duration(seconds: 150);
const Duration defaultExpectedVideo = Duration(seconds: 110);

/// Запас к ожидаемому времени следующей модели (плюс время отправки).
const Duration reserveMargin = Duration(seconds: 10);

/// Раньше 150 с текущую модель можно прервать ради следующей, только если
/// она уже ждала столько своих ожидаемых времён («честный шанс»).
const double fairChance = 1.25;

/// Следующая модель запускается, только если до потолка осталось не меньше
/// этой доли её ожидаемого времени (и не меньше [minAttemptTime]).
const double startShare = 0.8;

/// Когда прервать ожидание начала ответа (от начала обращения к ИИ);
/// null — не прерывать (следующей модели заведомо не хватит времени).
/// [sendEnd] — конец отправки текущей попытки, [sendTime] — сколько заняла
/// отправка (следующей модели понадобится примерно столько же).
Duration? startLimitAt({
  required Duration sendEnd,
  required Duration sendTime,
  required Duration timeLimit,
  required Duration startLimit,
  required Duration currentExpected,
  required Duration nextExpected,
}) {
  final need = nextExpected + sendTime + reserveMargin;
  final regular = sendEnd + startLimit;
  if (timeLimit - regular >= need) return regular;
  // Раньше 150 с — только если текущая модель уже получила честный шанс.
  final early = timeLimit - need;
  final fair = sendEnd + currentExpected * fairChance;
  if (early >= fair && early > sendEnd) return early;
  return null;
}

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
  const AttemptNotice(
      {required this.reason, required this.model, this.nextModel, this.pause});

  /// Пауза перед повтором той же модели (поминутная квота).
  final Duration? pause;

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

  /// Полный текст ошибки провайдера (без ключа, до 8000 символов).
  String? errorFull;

  /// 429: вид квоты (`minute` / `day`) и её id.
  String? quota;
  String? quotaId;

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
        'error_full': errorFull,
        'quota': quota,
        'quota_id': quotaId,
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

  /// Время обращения к ИИ (от загрузки или первого запроса) — потолок
  /// считается от него.
  Duration? aiTime;

  /// Предварительная проверка (ключ, модель, страна) — параллельно с
  /// подготовкой видео.
  PrecheckResult? precheck;

  /// Как ушёл материал (один раз через File API или в каждой попытке) и
  /// заметки об удалении загруженного файла.
  SharedMaterial? upload;
  final List<String> uploadNotes = [];

  /// Почему модели цепочки пропущены (не хватает времени).
  final List<String> chainNotes = [];
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
    this.expectedTime,
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

  /// Предел ожидания начала ответа (в тестах — другой).
  final Duration startLimit;

  /// Ожидаемое время ответа модели в режиме (providers.json, `expected_sec`);
  /// null — значения по умолчанию.
  final Duration? Function(String model, SubmissionMode mode)? expectedTime;

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
    // Потолок — от начала обращения к ИИ (загрузка материала или первый
    // запрос), без проверки видео, сжатия и анализа музыки (spec 7.7).
    final ai = Stopwatch();
    Duration expected(String model) =>
        expectedTime?.call(model, mode) ??
        (mode == SubmissionMode.video
            ? defaultExpectedVideo
            : defaultExpectedFrames);
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
    AiSharedMaterial? sharer;
    SharedMaterial? shared;
    try {
      workDir = await tempStorage.createWorkDir();
      cancel.throwIfCancelled();

      // Предварительная проверка (ключ, модель, страна) — параллельно с
      // подготовкой; фатальный ответ отменяет подготовку сразу.
      final prepCancel = CancelToken();
      unawaited(cancel.whenCancelled.then((_) => prepCancel.cancel()));
      AiException? fatal;
      Future<void>? precheck;
      final p = provider;
      if (p is AiPrecheck && !demo) {
        precheck = (p as AiPrecheck).precheck(prepCancel).then((r) {
          trace?.precheck = r;
          final e = r.error;
          if (e != null && _precheckFatal.contains(e.kind)) {
            fatal = e;
            prepCancel.cancel();
          }
        }, onError: (Object _) {});
      }
      AnalysisFailure fatalFailure(AiException e) => AnalysisFailure.fromAi(e,
          videoMode: mode == SubmissionMode.video,
          providerName: provider.displayName);

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
          cancel: prepCancel,
        );
      } on PrepareException catch (e) {
        throw AnalysisFailure.fromPrepare(e);
      } on AnalysisCancelled {
        final f = fatal;
        if (f != null && !cancel.isCancelled) throw fatalFailure(f);
        rethrow;
      }
      cancel.throwIfCancelled();
      // Проверка ещё идёт — дождаться (у неё свой таймаут).
      if (precheck != null) await precheck;
      final f0 = fatal;
      if (f0 != null) throw fatalFailure(f0);
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

      // Обращение к ИИ начинается: отсюда — потолок.
      ai.start();

      // Материал — один раз на весь анализ (например, видео в File API):
      // все попытки и модели цепочки используют его (spec 7.7).
      if (p is AiSharedMaterial && !demo) {
        sharer = p as AiSharedMaterial;
        final upCancel = CancelToken();
        final upSub = cancel.whenCancelled.then((_) => upCancel.cancel());
        var upTimedOut = false;
        final upTimer = Timer(timeLimit, () {
          upTimedOut = true;
          upCancel.cancel();
        });
        try {
          shared = await sharer.prepareShared(
            request,
            onProgress: (p) => onProgress(AnalysisProgress(
              p.phase == AiPhase.processing
                  ? AnalysisStage.processing
                  : AnalysisStage.sending,
              fraction: p.phase == AiPhase.sending ? p.fraction : null,
            )),
            cancel: upCancel,
          );
        } on AiException catch (e) {
          trace?.uploadNotes.addAll(e.notes);
          throw fatalFailure(e);
        } on AnalysisCancelled {
          if (upTimedOut && !cancel.isCancelled) {
            throw AnalysisFailure(FailureKind.timeLimit, details: [
              'материал не загрузился до потолка ${timeLimit.inSeconds} с',
            ]);
          }
          rethrow;
        } finally {
          upTimer.cancel();
          unawaited(upSub);
        }
        trace?.upload = shared;
        if (shared != null) request = request.withShared(shared.handle);
      }

      final base = request;
      var current = provider;
      var modelIndex = 0;
      var sameModelRetried = false;
      var quotaRetried = false;
      var correctionUsed = false;
      var pauseIndex = 0;
      var nextPause = Duration.zero;
      var nextReason = AttemptReason.first;
      Duration? lastAnswerTime;
      AiException? lastError;
      var sawOverload = false;
      var sawDailyQuota = false;

      // Повторы и запасные исчерпаны (или на них нет времени). Время сброса
      // квоты — только если был 429 дневной квоты.
      AnalysisFailure exhausted(String why) {
        final video = mode == SubmissionMode.video;
        final hint = sawDailyQuota ? overloadHintRu : null;
        if (sawOverload || lastError == null) {
          return AnalysisFailure(FailureKind.overloaded,
              details: [why, ?lastError?.detail],
              hintRu: hint,
              videoMode: video,
              framesFallback: video && framesOnly.isNotEmpty);
        }
        final f = AnalysisFailure.fromAi(lastError,
            videoMode: video, providerName: provider.displayName, hintRu: hint);
        return f.withDetails([why, ...f.details]);
      }

      // Следующая модель цепочки, которой хватает времени; пропущенные —
      // в заметки. null — ни одной.
      int? nextFitting() {
        final remaining = timeLimit - ai.elapsed;
        for (var i = modelIndex + 1; i < chain.length; i++) {
          final share = expected(chain[i]) * startShare;
          final need = share > minAttemptTime ? share : minAttemptTime;
          if (remaining >= need) return i;
          trace?.chainNotes.add('${chain[i]} пропущена: ожидается '
              '${expected(chain[i]).inSeconds} с, до потолка '
              '${remaining.inSeconds} с');
        }
        return null;
      }

      while (true) {
        final isRetry = nextReason == AttemptReason.invalidResponse;
        var remaining = timeLimit - ai.elapsed;
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
              details: ['потолок исчерпан до первого запроса']);
        }
        if (nextPause > Duration.zero) {
          await _pause(nextPause, cancel);
          remaining = timeLimit - ai.elapsed;
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
        // и есть следующая модель. Момент — [startLimitAt]: не прерываем,
        // если следующей модели заведомо не хватит времени.
        final nextModel =
            modelIndex + 1 < chain.length ? chain[modelIndex + 1] : null;
        final limitStart =
            current.capabilities.streamsResponse && nextModel != null;
        Timer? startTimer;
        var answerStarted = false;
        Duration? noResponseAfter;
        int? lastSent;
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
              final sendEnd = ai.elapsed;
              final at = startLimitAt(
                sendEnd: sendEnd,
                sendTime: sw.elapsed,
                timeLimit: timeLimit,
                startLimit: startLimit,
                currentExpected: expected(current.model),
                nextExpected: expected(nextModel),
              );
              if (at == null) return;
              final wait = at - sendEnd;
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
              if (p.sentBytes != null) lastSent = p.sentBytes;
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
            ..sentBytes = e.sentBytes ?? lastSent
            ..notes = e.notes
            ..diag = e.diag
            ..errorFull = e.fullDetail
            ..quota = e.quota?.name
            ..quotaId = e.quotaId
            ..error =
                '${e.kind.name}${e.detail == null ? '' : ': ${e.detail}'}';
          failed = e;
        } on AnalysisCancelled {
          record
            ..totalTime = sw.elapsed
            ..sentBytes = lastSent;
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
              if (e.quota == QuotaScope.day) sawDailyQuota = true;
              // Поминутная квота — пауза по retryDelay и повтор той же
              // модели, если после паузы ей хватит времени.
              final wait = e.retryAfter;
              if (e.quota == QuotaScope.minute && wait != null && !quotaRetried) {
                final exp = expected(current.model);
                final need = wait + (exp > minAttemptTime ? exp : minAttemptTime);
                if (timeLimit - ai.elapsed >= need) {
                  quotaRetried = true;
                  nextPause = wait;
                  nextReason = reason;
                  onProgress(AnalysisProgress(AnalysisStage.sending,
                      notice: AttemptNotice(
                          reason: reason, model: current.model, pause: wait)));
                  continue;
                }
              }
            case AiErrorKind.modelUnavailable when modelIndex > 0:
              reason = AttemptReason.modelUnavailable;
            default:
              // Ключ, сеть, размер, фильтры, страна, модель пользователя —
              // без цепочки.
              throw AnalysisFailure.fromAi(e,
                  videoMode: mode == SubmissionMode.video,
                  providerName: provider.displayName,
                  hintRu: e.kind == AiErrorKind.rateLimit && sawDailyQuota
                      ? overloadHintRu
                      : null);
          }
          if (modelIndex + 1 >= chain.length) {
            throw exhausted(chain.length > 1
                ? 'все модели цепочки перегружены или недоступны'
                : e.kind == AiErrorKind.noResponse
                    ? 'сервер не начал отвечать'
                    : 'повторы не помогли');
          }
          final next = nextFitting();
          if (next == null) {
            throw exhausted('на следующие модели цепочки не хватает времени '
                '(осталось ${(timeLimit - ai.elapsed).inSeconds} с)');
          }
          final failedModel = current.model;
          modelIndex = next;
          current = providerFor!(chain[modelIndex]);
          sameModelRetried = false;
          quotaRetried = false;
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
      // Загруженный материал удаляется в любом исходе (spec 7.7).
      final s = shared;
      final r = sharer;
      if (s != null && r != null) {
        final notes = <String>[];
        await r.releaseShared(s, notes);
        trace?.uploadNotes.addAll(notes);
      }
      trace
        ?..totalTime = total.elapsed
        ..aiTime = ai.isRunning || ai.elapsed > Duration.zero ? ai.elapsed : null;
      if (workDir != null) await tempStorage.deleteDir(workDir);
    }
  }

  /// Ответ предварительной проверки, при котором анализ бессмыслен.
  static const _precheckFatal = {
    AiErrorKind.invalidKey,
    AiErrorKind.keyFormat,
    AiErrorKind.regionBlocked,
    AiErrorKind.modelUnavailable,
  };
}
