import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dance_ai/analysis/cancel_token.dart';
import 'package:dance_ai/analysis/media/media_tool.dart';

/// Подделка FFmpeg: пишет файлы-кадры и PCM во временную папку анализа,
/// умеет падать и «зависать» до отмены на любом шаге.
class FakeMediaTool implements MediaTool {
  FakeMediaTool({
    this.info = const MediaInfo(
        durationSec: 40, hasAudio: true, hasVideo: true, width: 1920, height: 1080),
    this.audio,
    this.frameCountOverride,
    this.failFrames = false,
    this.failAudio = false,
    this.hangOnFrames = false,
    this.hangOnAudio = false,
    this.failLight = false,
    this.hangOnLight = false,
    this.lightSizeBytes = 4000,
  });

  final MediaInfo? info;

  /// Звук, который «извлекается»; null — тишина 10 с.
  final Float32List? audio;

  /// Сколько кадров вернуть (по умолчанию — по длительности и частоте).
  final int? frameCountOverride;
  final bool failFrames;
  final bool failAudio;
  final bool hangOnFrames;
  final bool hangOnAudio;
  final bool failLight;
  final bool hangOnLight;

  /// Размер «облегчённой копии».
  final int lightSizeBytes;
  String? lastLightPath;

  final calls = <String>[];
  double? lastFps;
  int? lastMaxLongSide;

  /// Завершается, когда инструмент начал «зависшую» операцию.
  final hanging = Completer<void>();

  @override
  Future<MediaInfo?> probe(String input) async {
    calls.add('probe');
    return info;
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
    calls.add('frames');
    lastFps = fps;
    lastMaxLongSide = maxLongSidePx;
    final n = frameCountOverride ?? ((durationSec ?? 10) * fps).floor();
    final paths = <String>[];
    for (var i = 0; i < n; i++) {
      final f = File('$outDir/f_${(i + 1).toString().padLeft(5, '0')}.jpg')
        ..writeAsBytesSync([i % 256, 1, 2, 3]);
      paths.add(f.path);
    }
    onProgress(0.5);
    await _maybeHang(hangOnFrames, cancel);
    if (failFrames) throw const MediaToolException('decode error');
    return paths;
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
    calls.add('audio');
    final samples = audio ?? Float32List(sampleRate * 10);
    File(outFile).writeAsBytesSync(samples.buffer.asUint8List(
        samples.offsetInBytes, samples.lengthInBytes));
    await _maybeHang(hangOnAudio, cancel);
    if (failAudio) throw const MediaToolException('no audio decoder');
  }

  @override
  Future<LightVideo> transcodeLight({
    required String input,
    required String outFile,
    required LightVideoOptions options,
    required double? durationSec,
    required void Function(double fraction) onProgress,
    required CancelToken cancel,
  }) async {
    calls.add('light');
    lastLightPath = outFile;
    File(outFile).writeAsBytesSync(List.filled(lightSizeBytes, 7));
    onProgress(0.5);
    await _maybeHang(hangOnLight, cancel);
    if (failLight) throw const MediaToolException('no encoder');
    return LightVideo(
        path: outFile, sizeBytes: lightSizeBytes, codec: 'fake', width: 854, height: 480);
  }

  Future<void> _maybeHang(bool hang, CancelToken cancel) async {
    if (!hang) return;
    if (!hanging.isCompleted) hanging.complete();
    await cancel.whenCancelled;
    throw const AnalysisCancelled();
  }
}
