import 'dart:io';
import 'dart:isolate';

import 'cancel_token.dart';
import 'mp4_probe.dart';
import 'video_preparer.dart';

/// Временная подготовка видео (до шага 4 плана): без нативных библиотек.
/// - проверка файла, длительность и наличие звука — разбором MP4/MOV;
///   у других контейнеров длительность и звук неизвестны (не блокируем);
/// - кадров нет;
/// - анализ музыки — «Анализ музыки недоступен.».
/// Настоящая реализация заменит этот класс, не меняя интерфейс.
class BasicVideoPreparer implements VideoPreparer {
  const BasicVideoPreparer();

  @override
  Future<VideoProbe> probe(String videoPath) async {
    final file = File(videoPath);
    if (!await file.exists()) return const VideoProbe(readable: false);
    try {
      // Разбор — в отдельном изоляте, чтобы не трогать UI-поток.
      final info = await Isolate.run(() => probeMp4(videoPath));
      if (info == null) return const VideoProbe(readable: true);
      return VideoProbe(
        readable: true,
        durationSec: info.durationSec,
        hasAudio: info.hasAudio,
        hasVideo: info.hasVideo,
      );
    } on FileSystemException {
      return const VideoProbe(readable: false);
    }
  }

  @override
  Future<PreparedMaterial> prepare(
    PrepareRequest request, {
    required void Function(PrepareProgress) onProgress,
    required CancelToken cancel,
  }) async {
    onProgress(const PrepareProgress(PrepareStage.checkingVideo));
    final probeResult = await probe(request.videoPath);
    cancel.throwIfCancelled();
    if (!probeResult.readable) {
      throw const PrepareException(PrepareErrorKind.unreadable);
    }
    if (probeResult.hasAudio == false) {
      throw const PrepareException(PrepareErrorKind.noAudio);
    }
    onProgress(const PrepareProgress(PrepareStage.checkingVideo, 1));

    onProgress(const PrepareProgress(PrepareStage.extractingFrames));
    await cancel.delay(const Duration(milliseconds: 350));
    onProgress(const PrepareProgress(PrepareStage.extractingFrames, 1));

    onProgress(const PrepareProgress(PrepareStage.analyzingMusic));
    await cancel.delay(const Duration(milliseconds: 350));
    onProgress(const PrepareProgress(PrepareStage.analyzingMusic, 1));

    return PreparedMaterial(
      videoPath: request.videoPath,
      durationSec: probeResult.durationSec,
      frames: const [],
      fps: request.frameOptions.fps,
      musicAnalysis: musicAnalysisUnavailable,
    );
  }
}
