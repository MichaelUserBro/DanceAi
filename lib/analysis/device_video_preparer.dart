import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'cancel_token.dart';
import 'media/ffmpeg_media_tool.dart';
import 'media/media_tool.dart';
import 'music/music_analyzer.dart';
import 'music/music_isolate.dart';
import 'video_preparer.dart';

/// Делает уменьшенную копию кадра (PNG) для «Для разработчика».
typedef Thumbnailer = Future<Uint8List?> Function(Uint8List image, int longSide);

/// Подготовка видео на устройстве (spec 7.4):
/// проверка звука и длительность → кадры с метками времени → звук →
/// анализ музыки (spec 7.6). FFmpeg работает в нативных потоках, анализ
/// музыки — в отдельном изоляте; UI-поток свободен.
/// Всё производное пишется только в `request.workDir` — её удаляет конвейер.
class DeviceVideoPreparer implements VideoPreparer {
  DeviceVideoPreparer({
    MediaTool? tool,
    Thumbnailer? thumbnailer,
    this.audioSampleRate = 22050,
    this.previewCount = 6,
    this.previewLongSide = 320,
  })  : tool = tool ?? const FfmpegMediaTool(),
        thumbnailer = thumbnailer ?? pngThumbnail;

  final MediaTool tool;
  final Thumbnailer thumbnailer;
  final int audioSampleRate;
  final int previewCount;
  final int previewLongSide;

  @override
  Future<VideoProbe> probe(String videoPath) async {
    try {
      final info = await tool.probe(videoPath);
      if (info == null || !info.hasVideo) return const VideoProbe(readable: false);
      return VideoProbe(
        readable: true,
        durationSec: info.durationSec,
        hasAudio: info.hasAudio,
        hasVideo: info.hasVideo,
      );
    } on Exception {
      return const VideoProbe(readable: false);
    }
  }

  @override
  Future<PreparedMaterial> prepare(
    PrepareRequest request, {
    required void Function(PrepareProgress) onProgress,
    required CancelToken cancel,
  }) async {
    final diag = request.diagnostics ?? PrepareDiagnostics();
    final sw = Stopwatch()..start();
    final sep = Platform.pathSeparator;

    // 1–2. Файл читается, есть звук; длительность.
    onProgress(const PrepareProgress(PrepareStage.checkingVideo));
    final MediaInfo? info;
    try {
      info = await tool.probe(request.videoPath);
    } on Exception catch (e) {
      diag.notes.add('probe: ${_short(e)}');
      throw const PrepareException(PrepareErrorKind.unreadable);
    }
    cancel.throwIfCancelled();
    diag
      ..durationSec = info?.durationSec
      ..hasAudio = info?.hasAudio
      ..width = info?.width
      ..height = info?.height;
    if (info == null || !info.hasVideo) {
      throw const PrepareException(PrepareErrorKind.unreadable);
    }
    if (!info.hasAudio) throw const PrepareException(PrepareErrorKind.noAudio);
    final duration = info.durationSec;
    _lap(diag, PrepareStage.checkingVideo, sw);
    onProgress(const PrepareProgress(PrepareStage.checkingVideo, 1));

    // 3а. Видео целиком: облегчённая копия (spec 7.3). Исходник не копируется.
    LightVideo? light;
    if (request.mode == SubmissionMode.video) {
      onProgress(const PrepareProgress(PrepareStage.compressingVideo, 0));
      try {
        light = await tool.transcodeLight(
          input: request.videoPath,
          outFile: '${request.workDir.path}${sep}light.mp4',
          options: request.lightOptions,
          durationSec: duration,
          onProgress: (f) =>
              onProgress(PrepareProgress(PrepareStage.compressingVideo, f)),
          cancel: cancel,
        );
      } on MediaToolException catch (e) {
        diag.notes.add('сжатие видео: ${e.message}');
        throw const PrepareException(PrepareErrorKind.encodeFailed);
      }
      cancel.throwIfCancelled();
      diag
        ..lightVideoBytes = light.sizeBytes
        ..lightVideoCodec = light.codec
        ..lightVideoWidth = light.width
        ..lightVideoHeight = light.height;
      _lap(diag, PrepareStage.compressingVideo, sw);
      onProgress(const PrepareProgress(PrepareStage.compressingVideo, 1));
    }

    // 3б. Кадры (только при подаче кадрами, spec 7.3).
    var frames = const <VideoFrame>[];
    final opts = request.frameOptions;
    var fps = opts.fps;
    if (request.mode == SubmissionMode.frames) {
      onProgress(const PrepareProgress(PrepareStage.extractingFrames, 0));
      final plan = planFrameRate(
          fps: opts.fps, maxFrames: opts.maxFrames, durationSec: duration);
      fps = plan.fps;
      diag
        ..requestedFps = opts.fps
        ..thinned = plan.thinned;
      final dir = Directory('${request.workDir.path}${sep}frames');
      await dir.create();
      List<String> paths;
      try {
        paths = await tool.extractFrames(
          input: request.videoPath,
          outDir: dir.path,
          fps: fps,
          maxLongSidePx: opts.maxLongSidePx,
          durationSec: duration,
          onProgress: (f) =>
              onProgress(PrepareProgress(PrepareStage.extractingFrames, f)),
          cancel: cancel,
        );
      } on MediaToolException catch (e) {
        diag.notes.add('кадры: ${e.message}');
        throw const PrepareException(PrepareErrorKind.unreadable);
      }
      cancel.throwIfCancelled();
      if (paths.isEmpty) {
        diag.notes.add('кадры: ни одного кадра');
        throw const PrepareException(PrepareErrorKind.unreadable);
      }
      // Длительность неизвестна заранее — разрежаем после извлечения.
      final keep = evenlySpacedIndices(paths.length, opts.maxFrames);
      if (keep.length < paths.length) {
        diag.thinned = true;
        final kept = keep.toSet();
        for (var i = 0; i < paths.length; i++) {
          if (!kept.contains(i)) await File(paths[i]).delete();
        }
      }
      frames = [
        for (final i in keep) VideoFrame(timeSec: i / fps, path: paths[i]),
      ];
      if (keep.length < paths.length) {
        // Фактическая средняя частота после разрежения.
        fps = keep.length / (paths.length / fps);
      }
      diag
        ..frameCount = frames.length
        ..actualFps = fps;
      await _previews(frames, diag, cancel);
      _lap(diag, PrepareStage.extractingFrames, sw);
      onProgress(const PrepareProgress(PrepareStage.extractingFrames, 1));
    }

    // 4. Звук → анализ музыки. Неудача не мешает анализу танца.
    onProgress(const PrepareProgress(PrepareStage.analyzingMusic, 0));
    final music = await _music(request, duration, diag, onProgress, cancel);
    diag.musicText = music;
    _lap(diag, PrepareStage.analyzingMusic, sw);
    onProgress(const PrepareProgress(PrepareStage.analyzingMusic, 1));

    return PreparedMaterial(
      videoPath: request.videoPath,
      durationSec: duration,
      frames: frames,
      fps: fps,
      musicAnalysis: music,
      video: light,
    );
  }

  Future<String> _music(
    PrepareRequest request,
    double? duration,
    PrepareDiagnostics diag,
    void Function(PrepareProgress) onProgress,
    CancelToken cancel,
  ) async {
    final pcm = File(
        '${request.workDir.path}${Platform.pathSeparator}audio.f32');
    try {
      await tool.extractAudio(
        input: request.videoPath,
        outFile: pcm.path,
        sampleRate: audioSampleRate,
        durationSec: duration,
        // Извлечение — первые 70 % этапа, анализ — остальное.
        onProgress: (f) =>
            onProgress(PrepareProgress(PrepareStage.analyzingMusic, f * 0.7)),
        cancel: cancel,
      );
    } on MediaToolException catch (e) {
      diag.notes.add('звук: ${e.message}');
      return musicAnalysisUnavailable;
    }
    cancel.throwIfCancelled();
    onProgress(const PrepareProgress(PrepareStage.analyzingMusic, 0.7));

    try {
      // В изолят — только путь, частота и подсказка темпа (music_isolate.dart).
      // Отмена — здесь: перестаём ждать результат.
      final done = Completer<MusicResult>();
      analyzeMusicFileInIsolate(
        pcm.path,
        audioSampleRate,
        MusicHint.fromDance(request.dance.music),
      ).then((r) {
        if (!done.isCompleted) done.complete(r);
      }, onError: (Object e, StackTrace s) {
        if (!done.isCompleted) done.completeError(e, s);
      });
      unawaited(cancel.whenCancelled.then((_) {
        if (!done.isCompleted) done.completeError(const AnalysisCancelled());
      }));
      final result = await done.future;
      cancel.throwIfCancelled();
      diag
        ..audioRmsDb = result.rmsDb
        ..audioPeakDb = result.peakDb
        ..musicPeriodicity = result.periodicity
        ..musicAgreement = result.agreement;
      final a = result.analysis;
      if (a == null) {
        diag.notes.add('музыка: ${result.failure ?? 'ритм не найден'}');
        return musicAnalysisUnavailable;
      }
      diag
        ..bpm = a.bpm
        ..musicConfidence = a.confidence
        ..musicLevel = a.level;
      return a.toPromptText();
    } on AnalysisCancelled {
      rethrow;
    } on Object catch (e) {
      diag.notes.add('музыка: ${_short(e)}');
      return musicAnalysisUnavailable;
    } finally {
      // Звук больше не нужен — не ждём конца всего анализа.
      try {
        if (await pcm.exists()) await pcm.delete();
      } on FileSystemException {
        // Удалит конвейер вместе с папкой.
      }
    }
  }

  Future<void> _previews(
      List<VideoFrame> frames, PrepareDiagnostics diag, CancelToken cancel) async {
    diag.previews.clear();
    for (final i in evenlySpacedIndices(frames.length, previewCount)) {
      cancel.throwIfCancelled();
      try {
        final bytes = await File(frames[i].path).readAsBytes();
        final png = await thumbnailer(bytes, previewLongSide);
        if (png != null) {
          diag.previews.add(FramePreview(timeSec: frames[i].timeSec, image: png));
        }
      } on Object {
        // Превью — только для отладки; без него анализ идёт дальше.
      }
    }
  }

  static void _lap(PrepareDiagnostics d, PrepareStage stage, Stopwatch sw) {
    d.stageTimes[stage] = sw.elapsed;
    sw.reset();
  }

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }
}

/// Частота кадров с учётом лимита: если при [fps] кадров больше
/// [maxFrames] — частота равномерно снижается.
({double fps, bool thinned}) planFrameRate({
  required double fps,
  required int maxFrames,
  required double? durationSec,
}) {
  final d = durationSec;
  if (d == null || d <= 0 || d * fps <= maxFrames) {
    return (fps: fps, thinned: false);
  }
  return (fps: maxFrames / d, thinned: true);
}

/// [count] равномерно расположенных индексов из [length] (с первым и
/// последним); все, если [length] ≤ [count].
List<int> evenlySpacedIndices(int length, int count) {
  if (length <= count) return [for (var i = 0; i < length; i++) i];
  if (count <= 0) return const [];
  if (count == 1) return const [0];
  return [
    for (var k = 0; k < count; k++) ((k * (length - 1)) / (count - 1)).round(),
  ];
}

/// Уменьшение средствами движка Flutter (декодирование — не в UI-потоке).
Future<Uint8List?> pngThumbnail(Uint8List image, int longSide) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(image);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final w = descriptor.width;
  final h = descriptor.height;
  final scale = math.min(1.0, longSide / math.max(w, h));
  final codec = await descriptor.instantiateCodec(
    targetWidth: math.max(1, (w * scale).round()),
    targetHeight: math.max(1, (h * scale).round()),
  );
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return data?.buffer.asUint8List();
}
