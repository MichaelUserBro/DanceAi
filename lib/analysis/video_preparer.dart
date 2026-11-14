import 'dart:io';

import '../data/criteria.dart';
import 'cancel_token.dart';

/// Способ подачи материала ИИ (spec 7.3). Зависит от модели, а не от провайдера.
enum SubmissionMode { frames, video }

/// Быстрая проверка файла для экрана «Видео» и шага «проверка видео».
class VideoProbe {
  const VideoProbe({
    required this.readable,
    this.durationSec,
    this.hasAudio,
    this.hasVideo,
  });

  /// Файл существует и открывается.
  final bool readable;

  /// null — длительность определить не удалось.
  final double? durationSec;

  /// null — наличие звука проверить не удалось (неизвестный контейнер).
  final bool? hasAudio;
  final bool? hasVideo;
}

/// Кадр с меткой времени от начала видео (spec 7.3).
class VideoFrame {
  const VideoFrame({required this.timeSec, required this.path});

  final double timeSec;

  /// JPEG/PNG во временной папке анализа.
  final String path;

  /// Метка, которая ставится перед кадром: `t=12.50`.
  String get label => 't=${timeSec.toStringAsFixed(2)}';
}

/// Параметры кадров — задаёт адаптер (у моделей разные лимиты).
class FrameOptions {
  const FrameOptions({
    this.fps = 2,
    this.maxFrames = 120,
    this.maxLongSidePx = 768,
  });

  final double fps;
  final int maxFrames;
  final int maxLongSidePx;
}

class PrepareRequest {
  const PrepareRequest({
    required this.videoPath,
    required this.dance,
    required this.mode,
    required this.frameOptions,
    required this.workDir,
  });

  final String videoPath;

  /// Для подсказок анализа музыки: размер и темп из criteria.json.
  final Dance dance;
  final SubmissionMode mode;
  final FrameOptions frameOptions;

  /// Временная папка этого анализа. Всё производное — только сюда;
  /// конвейер удаляет её в любом исходе.
  final Directory workDir;
}

/// Готовый материал для ИИ.
class PreparedMaterial {
  const PreparedMaterial({
    required this.videoPath,
    required this.durationSec,
    required this.frames,
    required this.fps,
    required this.musicAnalysis,
  });

  final String videoPath;
  final double? durationSec;

  /// Пусто, если кадры не извлекались (подача видео целиком
  /// или временная реализация подготовки).
  final List<VideoFrame> frames;

  /// Фактическая частота кадров.
  final double fps;

  /// Текст по формату spec 7.6 или «Анализ музыки недоступен.».
  final String musicAnalysis;
}

enum PrepareStage { checkingVideo, extractingFrames, analyzingMusic }

class PrepareProgress {
  const PrepareProgress(this.stage, [this.fraction]);

  final PrepareStage stage;

  /// 0..1 внутри этапа; null — неопределённый прогресс.
  final double? fraction;
}

enum PrepareErrorKind { unreadable, noAudio }

class PrepareException implements Exception {
  const PrepareException(this.kind);
  final PrepareErrorKind kind;

  @override
  String toString() => 'PrepareException($kind)';
}

const musicAnalysisUnavailable = 'Анализ музыки недоступен.';

/// Подготовка видео на устройстве (spec 7.4). Тяжёлая работа — вне UI-потока,
/// с прогрессом и отменой.
abstract interface class VideoPreparer {
  Future<VideoProbe> probe(String videoPath);

  /// Бросает [PrepareException] (нет звука, не читается)
  /// и [AnalysisCancelled] при отмене.
  Future<PreparedMaterial> prepare(
    PrepareRequest request, {
    required void Function(PrepareProgress) onProgress,
    required CancelToken cancel,
  });
}
