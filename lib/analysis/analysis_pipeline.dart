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
  const AnalysisProgress(this.stage, {this.fraction, this.isRetry = false});

  final AnalysisStage stage;
  final double? fraction;

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
  })  : _validator = ReportValidator(data.criteria),
        _prompts = PromptBuilder(data);

  final AppData data;
  final VideoPreparer preparer;
  final AiProvider provider;
  final TempStorage tempStorage;

  /// Анализ идёт через заглушку («Демо-режим»).
  final bool demo;
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
  }) async {
    final caps = provider.capabilities;
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
          : null;
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
            frameOptions: caps.frameOptions,
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
      );

      for (var attempt = 0; attempt < 2; attempt++) {
        final isRetry = attempt > 0;
        onProgress(AnalysisProgress(AnalysisStage.sending, isRetry: isRetry));
        final record = AiAttempt(retry: isRetry);
        trace?.attempts.add(record);
        final sw = Stopwatch()..start();
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
                isRetry: isRetry,
              ));
            },
            cancel: cancel,
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
            ..error =
                '${e.kind.name}${e.detail == null ? '' : ': ${e.detail}'}';
          throw AnalysisFailure.fromAi(e,
              videoMode: mode == SubmissionMode.video);
        }
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
