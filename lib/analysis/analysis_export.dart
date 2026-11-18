import 'dart:convert';

import '../app/app_version.dart';
import '../data/app_data.dart';
import '../report/overall_score.dart';
import '../report/report.dart';
import 'analysis_pipeline.dart';
import 'video_preparer.dart';

/// «Сохранить JSON» в «Для разработчика» (spec 7.8): итоговый отчёт,
/// сведения о подаче и сырые ответы — для сравнения моделей и версий
/// промпта на эталонном наборе (шаг 7). Ключа и промпта-картинок здесь нет:
/// [AnalysisTrace] их не содержит.
Map<String, Object?> analysisExport(AnalysisTrace t, AppData data) {
  final d = t.prepare;
  final video = t.mode == SubmissionMode.video;
  return {
    'export_version': 1,
    'app_version': appVersion,
    'criteria_version': data.criteria.version,
    'content_sha256': data.contentHashes,
    'created_at': (t.startedAt ?? DateTime.now()).toIso8601String(),
    'dance_id': t.danceId,
    'provider': t.providerName,
    'model': t.model,
    'requested_model': t.model,
    'answered_model': t.answeredModel,
    'use_fallback_models': t.useFallbackModels,
    'model_chain': t.modelChain,
    'demo': t.demo,
    'thinking_level': t.thinkingLevel,
    'max_frames_setting': t.maxFramesSetting,
    'submission': {
      'mode': t.mode?.name,
      'duration_sec': t.durationSec ?? d.durationSec,
      'source_width': d.width,
      'source_height': d.height,
      if (video) ...{
        'video_bytes': d.lightVideoBytes,
        'video_codec': d.lightVideoCodec,
        'video_width': d.lightVideoWidth,
        'video_height': d.lightVideoHeight,
        'model_video_fps': t.videoFps,
      } else ...{
        'frame_count': d.frameCount ?? t.frameCount,
        'requested_fps': d.requestedFps,
        'actual_fps': d.actualFps,
        'frames_thinned': d.thinned,
      },
    },
    'music': {
      'text': t.musicAnalysis ?? d.musicText,
      'bpm': d.bpm,
      'confidence': d.musicConfidence,
      'level': d.musicLevel?.name,
    },
    'timing_ms': {
      for (final e in d.stageTimes.entries) e.key.name: e.value.inMilliseconds,
      'total': t.totalTime?.inMilliseconds,
    },
    'retried': t.retried,
    'attempts': [for (final a in t.attempts) a.toJson()],
    'validation_problems': t.problems,
    'failure': t.failure,
    'overall_score': exportOverallScore(t, data),
    'report': t.reportJson,
    'raw_responses': t.responses,
    'notes': d.notes,
  };
}

/// Общая оценка, как на экране отчёта (spec 6); null — отчёта нет.
double? exportOverallScore(AnalysisTrace t, AppData data) {
  final json = t.reportJson;
  if (json == null) return null;
  try {
    return overallScore(DanceReport.fromJson(json),
        [for (final c in data.criteria.components) c.id]);
  } catch (_) {
    return null;
  }
}

String analysisExportText(AnalysisTrace t, AppData data) =>
    const JsonEncoder.withIndent('  ').convert(analysisExport(t, data));

/// `danceai_<танец>_<модель>_<ГГГГММДД-ЧЧММСС>.json` — только безопасные
/// для имени файла символы.
String analysisExportFileName(AnalysisTrace t) {
  final at = t.startedAt ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp = '${at.year}${two(at.month)}${two(at.day)}-'
      '${two(at.hour)}${two(at.minute)}${two(at.second)}';
  String safe(String? s) =>
      (s ?? 'unknown').replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
  final model = t.demo ? 'demo' : safe(t.model);
  return 'danceai_${safe(t.danceId)}_${model}_$stamp.json';
}
