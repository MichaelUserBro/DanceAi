import 'dart:async';
import 'dart:io';

import '../data/app_data.dart';
import '../data/criteria.dart';
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

class AnalysisProgress {
  const AnalysisProgress(this.stage,
      {this.fraction, this.isRetry = false, this.receivedBytes});

  final AnalysisStage stage;
  final double? fraction;

  /// Получено байт ответа (потоковая отдача) — живой прогресс «Анализ».
  final int? receivedBytes;

  /// Идёт повторный запрос после неудачной проверки ответа.
  final bool isRetry;
}

/// Один запрос к ИИ (первый или повторный) — для «Для разработчика».
class AiAttempt {
  AiAttempt({required this.retry});

  final bool retry;

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

  /// Провайдер и модель (имя из каталога, не ключ).
  String? providerName;
  String? model;
  bool demo = false;

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
  const AnalysisResult({required this.report, required this.retried});

  final DanceReport report;
  final bool retried;
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
  })  : _validator = ReportValidator(data.criteria),
        _prompts = PromptBuilder(data);

  final AppData data;
  final VideoPreparer preparer;
  final AiProvider provider;
  final TempStorage tempStorage;

  /// Анализ идёт через заглушку («Демо-режим»).
  final bool demo;

  /// Потолок на весь анализ (в тестах — короче).
  final Duration timeLimit;
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
      ..maxFramesSetting = maxFrames;
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

      Duration? firstAttempt;
      for (var attempt = 0; attempt < 2; attempt++) {
        final isRetry = attempt > 0;
        final remaining = timeLimit - total.elapsed;
        if (isRetry) {
          // Повтор — только если на него остаётся разумное время.
          final need = firstAttempt != null && firstAttempt > minRetryTime
              ? firstAttempt
              : minRetryTime;
          if (remaining < need) {
            throw AnalysisFailure(FailureKind.timeLimit, details: [
              'первый ответ не прошёл проверку, на повтор не хватает времени '
                  '(осталось ${remaining.inSeconds} с)',
            ]);
          }
        }
        if (remaining <= Duration.zero) {
          throw const AnalysisFailure(FailureKind.timeLimit,
              details: ['потолок исчерпан на подготовке']);
        }
        onProgress(AnalysisProgress(AnalysisStage.sending, isRetry: isRetry));
        final record = AiAttempt(retry: isRetry);
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
        final String raw;
        try {
          final response = await provider.analyze(
            request,
            onProgress: (p) {
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
            ..notes = response.notes;
        } on AiException catch (e) {
          record
            ..totalTime = sw.elapsed
            ..notes = e.notes
            ..error =
                '${e.kind.name}${e.detail == null ? '' : ': ${e.detail}'}';
          throw AnalysisFailure.fromAi(e,
              videoMode: mode == SubmissionMode.video);
        } on AnalysisCancelled {
          record.totalTime = sw.elapsed;
          if (timedOut && !cancel.isCancelled) {
            record.error = 'timeLimit';
            throw AnalysisFailure(FailureKind.timeLimit, details: [
              'ответ не пришёл до потолка ${timeLimit.inSeconds} с',
            ]);
          }
          rethrow;
        } finally {
          timer.cancel();
          unawaited(userSub);
        }
        firstAttempt ??= sw.elapsed;
        cancel.throwIfCancelled();
        trace?.responses.add(raw);

        onProgress(AnalysisProgress(AnalysisStage.validating, isRetry: isRetry));
        final outcome = parseReport(raw, dance: dance, validator: _validator);
        switch (outcome) {
          case ParsedReport(:final report, :final json):
            trace?.reportJson = json;
            return AnalysisResult(report: report, retried: isRetry);
          case InvalidReport(:final problems):
            trace?.problems.add(problems);
            if (isRetry) {
              throw AnalysisFailure(FailureKind.invalidResponse,
                  details: problems);
            }
            request = request.retry(
              note: _prompts.retryNote(problems),
              previous: raw,
            );
        }
      }
      throw const AnalysisFailure(FailureKind.internal);
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
