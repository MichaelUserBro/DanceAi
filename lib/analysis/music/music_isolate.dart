import 'dart:io';
import 'dart:isolate';

import 'music_analyzer.dart';

/// Анализ музыки PCM-файла (моно, float32 little-endian) в отдельном изоляте.
///
/// Функция top-level намеренно: замыкание для [Isolate.run] создаётся здесь,
/// и его контекст — только [pcmPath], [sampleRate], [hint] (простые данные).
/// Замыкание, созданное внутри метода, уносит в изолят весь контекст метода
/// (this, колбэки прогресса, CancelToken, Timer экрана) — и падает с
/// «object is unsendable». Результат — тоже простые данные.
///
/// Отмена — на стороне вызывающего: он перестаёт ждать результат;
/// изолят сам завершится после анализа (секунды).
Future<MusicResult> analyzeMusicFileInIsolate(
  String pcmPath,
  int sampleRate,
  MusicHint hint,
) =>
    Isolate.run(() => analyzeMusicFile(pcmPath, sampleRate, hint));

/// То же синхронно (внутри изолята).
MusicResult analyzeMusicFile(String pcmPath, int sampleRate, MusicHint hint) {
  final bytes = File(pcmPath).readAsBytesSync();
  final samples = bytes.buffer.asFloat32List(0, bytes.length ~/ 4);
  return const MusicAnalyzer().analyzeDetailed(samples, sampleRate, hint);
}
