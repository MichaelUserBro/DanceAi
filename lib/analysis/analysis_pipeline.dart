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
  extractingFrames('Кадры'),
  analyzingMusic('Музыка'),
  sending('Отправка'),
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

/// Что видно в разделе «Для разработчика» о последнем анализе.
/// Только в памяти; ключа здесь нет.
class AnalysisTrace {
  BuiltPrompt? prompt;
  SubmissionMode? mode;
  String? musicAnalysis;
  double? durationSec;
  int? frameCount;

  /// Подготовка видео: сведения, превью кадров, время стадий (spec 7.8).
  final PrepareDiagnostics prepare = PrepareDiagnostics();
  final List<String> responses = [];
  final List<List<String>> problems = [];
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
  })  : _validator = ReportValidator(data.criteria),
        _prompts = PromptBuilder(data);

  final AppData data;
  final VideoPreparer preparer;
  final AiProvider provider;
  final TempStorage tempStorage;
  final ReportValidator _validator;
  final PromptBuilder _prompts;

  /// [wantVideo] — в настройках включено «Модель принимает видео со звуком».
  Future<AnalysisResult> run({
    required Dance dance,
    required String videoPath,
    required bool wantVideo,
    required CancelToken cancel,
    required void Function(AnalysisProgress) onProgress,
    AnalysisTrace? trace,
  }) async {
    final caps = provider.capabilities;
    final mode = wantVideo && caps.supportsVideo
        ? SubmissionMode.video
        : SubmissionMode.frames;
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

      final prompt =
          _prompts.build(dance: dance, mode: mode, material: material);
      trace
        ?..prompt = prompt
        ..mode = mode
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
      );

      for (var attempt = 0; attempt < 2; attempt++) {
        final isRetry = attempt > 0;
        onProgress(AnalysisProgress(AnalysisStage.sending, isRetry: isRetry));
        final String raw;
        try {
          raw = await provider.analyze(
            request,
            onPhase: (phase) => onProgress(AnalysisProgress(
              phase == AiPhase.sending
                  ? AnalysisStage.sending
                  : AnalysisStage.analyzing,
              isRetry: isRetry,
            )),
            cancel: cancel,
          );
        } on AiException catch (e) {
          throw AnalysisFailure.fromAi(e);
        }
        cancel.throwIfCancelled();
        trace?.responses.add(raw);

        onProgress(AnalysisProgress(AnalysisStage.validating, isRetry: isRetry));
        final outcome = parseReport(raw, dance: dance, validator: _validator);
        switch (outcome) {
          case ParsedReport(:final report):
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
    } on AnalysisFailure {
      rethrow;
    } on AnalysisCancelled {
      rethrow;
    } catch (e) {
      // Неожиданная ошибка: без текста исключения в интерфейсе.
      throw AnalysisFailure(FailureKind.internal, details: [e.runtimeType.toString()]);
    } finally {
      if (workDir != null) await tempStorage.deleteDir(workDir);
    }
  }
}
