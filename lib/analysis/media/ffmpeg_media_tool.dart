import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';

import '../cancel_token.dart';
import 'media_tool.dart';

/// [MediaTool] на FFmpeg (ffmpeg_kit_flutter_new_min, LGPL 3.0).
/// FFmpeg работает в своих нативных потоках — UI-поток не занят.
class FfmpegMediaTool implements MediaTool {
  const FfmpegMediaTool();

  /// `content://` (Android, SAF) FFmpeg читает напрямую, без копирования:
  /// URI превращается в параметр `saf:N`. Каждый вызов — свой параметр
  /// (дескриптор закрывается после использования).
  Future<String> _resolve(String input) async {
    if (!input.startsWith('content://')) return input;
    final saf = await FFmpegKitConfig.getSafParameterForRead(input);
    if (saf == null) throw const MediaToolException('SAF недоступен');
    return saf;
  }

  @override
  Future<MediaInfo?> probe(String input) async {
    if (!input.startsWith('content://') && !await File(input).exists()) {
      return null;
    }
    final session = await FFprobeKit.getMediaInformation(await _resolve(input));
    final info = session.getMediaInformation();
    if (info == null) return null;
    final streams = info.getStreams();
    final video = streams.where((s) => s.getType() == 'video').firstOrNull;
    return MediaInfo(
      durationSec: double.tryParse(info.getDuration() ?? ''),
      hasAudio: streams.any((s) => s.getType() == 'audio'),
      hasVideo: video != null,
      width: video?.getWidth(),
      height: video?.getHeight(),
    );
  }

  @override
  Future<List<String>> extractFrames({
    required String input,
    required String outDir,
    required double fps,
    required int maxLongSidePx,
    required double? durationSec,
    required void Function(double fraction) onProgress,
    required CancelToken cancel,
  }) async {
    final m = maxLongSidePx;
    await _run([
      '-v', 'error', '-nostdin', '-y',
      '-i', await _resolve(input),
      '-an', '-sn', '-dn',
      '-vf',
      // Кадр i — момент i / fps от начала; уменьшение по длинной стороне
      // без увеличения; поворот из метаданных FFmpeg учитывает сам.
      'fps=fps=${fps.toStringAsFixed(4)}:start_time=0,'
          "scale=w='if(gte(iw,ih),min($m,iw),-2)':h='if(gte(iw,ih),-2,min($m,ih))'",
      '-q:v', '4',
      '$outDir${Platform.pathSeparator}f_%05d.jpg',
    ], durationSec, onProgress, cancel);
    final files = await Directory(outDir)
        .list()
        .where((e) => e is File && e.path.endsWith('.jpg'))
        .map((e) => e.path)
        .toList();
    files.sort();
    return files;
  }

  @override
  Future<void> extractAudio({
    required String input,
    required String outFile,
    required int sampleRate,
    required double? durationSec,
    required void Function(double fraction) onProgress,
    required CancelToken cancel,
  }) async {
    await _run([
      '-v', 'error', '-nostdin', '-y',
      '-i', await _resolve(input),
      '-vn', '-sn', '-dn',
      '-ac', '1', '-ar', '$sampleRate',
      '-c:a', 'pcm_f32le', '-f', 'f32le',
      outFile,
    ], durationSec, onProgress, cancel);
  }

  Future<void> _run(
    List<String> args,
    double? durationSec,
    void Function(double) onProgress,
    CancelToken cancel,
  ) async {
    cancel.throwIfCancelled();
    final done = Completer<ReturnCode?>();
    final lastLog = StringBuffer();
    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (s) async {
        if (!done.isCompleted) done.complete(await s.getReturnCode());
      },
      (log) {
        // Только последняя ошибка — для «Для разработчика».
        lastLog
          ..clear()
          ..write(log.getMessage().trim());
      },
      (stats) {
        final d = durationSec;
        if (d != null && d > 0) {
          onProgress((stats.getTime() / 1000 / d).clamp(0.0, 1.0));
        }
      },
    );
    final id = session.getSessionId();
    unawaited(cancel.whenCancelled.then((_) {
      if (!done.isCompleted && id != null) FFmpegKit.cancel(id);
    }));
    final code = await done.future;
    if (cancel.isCancelled || ReturnCode.isCancel(code)) {
      throw const AnalysisCancelled();
    }
    if (!ReturnCode.isSuccess(code)) {
      throw MediaToolException(
          'ffmpeg ${code?.getValue()}: ${lastLog.toString()}');
    }
    onProgress(1);
  }
}
