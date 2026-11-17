import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dance_ai/analysis/music/music_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_data.dart';

/// Локальная проверка на реальных записях из зала. Видео лежат в
/// test_videos/ (не в репозитории), звук извлекает системный ffmpeg.
/// Нет видео или ffmpeg — тест пропускается.
void main() {
  final ref = jsonDecode(
          File('test/fixtures/music_reference.json').readAsStringSync())
      as Map<String, dynamic>;
  final tolerance = (ref['tolerance_bpm'] as num).toDouble();
  final videos = ref['videos'] as Map<String, dynamic>;
  final criteria = loadTestAppData().criteria;

  bool hasFfmpeg() {
    try {
      return Process.runSync('ffmpeg', ['-version']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  final ffmpeg = hasFfmpeg();

  for (final MapEntry(key: file, value: v) in videos.entries) {
    final path = 'test_videos/$file';
    final size = v['size_bytes'] as int?;
    final skip = !File(path).existsSync()
        ? 'нет $path'
        : size != null && File(path).lengthSync() != size
            ? '$path — другой файл, эталон снят не на нём'
            : !ffmpeg
                ? 'нет ffmpeg в PATH'
                : null;
    test('$file: темп в пределах ±$tolerance BPM от librosa', () async {
      final out = await Process.run(
        'ffmpeg',
        ['-v', 'error', '-nostdin', '-i', path, '-vn', '-ac', '1', '-ar',
          '22050', '-c:a', 'pcm_f32le', '-f', 'f32le', 'pipe:1'],
        stdoutEncoding: null,
      );
      expect(out.exitCode, 0, reason: '${out.stderr}');
      final bytes = Uint8List.fromList(out.stdout as List<int>);
      final samples = bytes.buffer.asFloat32List(0, bytes.length ~/ 4);
      final dance = criteria.dance(v['dance_id'] as String);
      final r = const MusicAnalyzer()
          .analyzeDetailed(samples, 22050, MusicHint.fromDance(dance.music));
      expect(r.analysis, isNotNull, reason: r.failure);
      final expected = (v['librosa_bpm'] as num).toDouble();
      expect((r.analysis!.bpm - expected).abs(), lessThanOrEqualTo(tolerance),
          reason: 'наш ${r.analysis!.bpm}, librosa $expected');
    }, skip: skip);
  }
}
