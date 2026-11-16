import 'dart:async';
import 'dart:io';

import 'package:dance_ai/analysis/cancel_token.dart';
import 'package:dance_ai/analysis/device_video_preparer.dart';
import 'package:dance_ai/analysis/media/media_tool.dart';
import 'package:dance_ai/analysis/music/music_analyzer.dart';
import 'package:dance_ai/analysis/music/music_isolate.dart';
import 'package:dance_ai/analysis/video_preparer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_media_tool.dart';
import '../metronome.dart';
import '../test_data.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('danceai_iso_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('анализ через Isolate.run: PCM-файл → результат (простые данные)',
      () async {
    final m = Metronome(bpm: 87, meter: 3, durationSec: 30);
    final file = File('${dir.path}/a.f32')
      ..writeAsBytesSync(m.render().buffer.asUint8List());
    // Объекты, которые нельзя передать в изолят, рядом с вызовом — как в
    // приложении. top-level функция их не захватывает.
    final timer = Timer.periodic(const Duration(seconds: 1), (_) {});
    addTearDown(timer.cancel);
    final r = await analyzeMusicFileInIsolate(
        file.path,
        sr,
        const MusicHint(
            meter: '3/4', beatsPerBar: 3, minMpm: 28, maxMpm: 30));
    expect(r.analysis, isNotNull, reason: r.failure);
    expect(r.analysis!.bpm, closeTo(87, 2));
    expect(r.rmsDb, isNotNull);
    expect(r.periodicity, greaterThan(0.1));
  });

  test('отмена во время анализа в изоляте — AnalysisCancelled, без '
      'необработанных ошибок', () async {
    final m = Metronome(bpm: 124, meter: 4, durationSec: 60);
    final cancel = CancelToken();
    final future = DeviceVideoPreparer(
      tool: FakeMediaTool(
          audio: m.render(),
          info: const MediaInfo(durationSec: 60, hasAudio: true, hasVideo: true)),
      thumbnailer: (img, side) async => null,
    ).prepare(
      PrepareRequest(
        videoPath: 'v.mp4',
        dance: loadTestAppData().criteria.dance('cha_cha'),
        mode: SubmissionMode.video,
        frameOptions: const FrameOptions(),
        workDir: dir,
      ),
      onProgress: (p) {
        // Звук извлечён — изолят вот-вот стартует; отменяем сразу после.
        if (p.stage == PrepareStage.analyzingMusic && p.fraction == 0.7) {
          scheduleMicrotask(() => Future<void>.delayed(
              const Duration(milliseconds: 5), cancel.cancel));
        }
      },
      cancel: cancel,
    );
    await expectLater(future, throwsA(isA<AnalysisCancelled>()));
    // Изолят дорабатывает сам; его результат никого не ломает.
    await Future<void>.delayed(const Duration(seconds: 2));
  });
}
