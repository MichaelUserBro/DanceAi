import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dance_ai/analysis/ai_provider.dart';
import 'package:dance_ai/analysis/analysis_failure.dart';
import 'package:dance_ai/analysis/analysis_pipeline.dart';
import 'package:dance_ai/analysis/cancel_token.dart';
import 'package:dance_ai/analysis/device_video_preparer.dart';
import 'package:dance_ai/analysis/media/media_tool.dart';
import 'package:dance_ai/analysis/temp_storage.dart';
import 'package:dance_ai/analysis/video_preparer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_media_tool.dart';
import '../metronome.dart';
import '../test_data.dart';

class _OkProvider implements AiProvider {
  _OkProvider(this.answer);
  final String answer;
  AiRequest? last;

  @override
  String get displayName => 'Тест';

  @override
  AiCapabilities get capabilities =>
      const AiCapabilities(supportsVideo: true, frameOptions: FrameOptions());

  @override
  String get model => 'test';

  @override
  Future<ModelLookup?> lookupModel(CancelToken cancel) async => null;

  @override
  Future<AiResponse> analyze(AiRequest request,
      {required void Function(AiProgress) onProgress,
      required CancelToken cancel}) async {
    last = request;
    return AiResponse(text: answer);
  }
}

Future<Uint8List?> _fakeThumb(Uint8List image, int longSide) async =>
    Uint8List.fromList([longSide ~/ 10, ...image.take(2)]);

void main() {
  final data = loadTestAppData();
  final waltz = data.criteria.dance('slow_waltz');
  final valid = jsonEncode(loadExampleReportJson());
  late Directory root;
  late Directory work;

  setUp(() {
    root = Directory.systemTemp.createTempSync('danceai_prep_');
    work = Directory('${root.path}/work')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  DeviceVideoPreparer preparer(FakeMediaTool tool) =>
      DeviceVideoPreparer(tool: tool, thumbnailer: _fakeThumb);

  Future<PreparedMaterial> prepare(
    FakeMediaTool tool, {
    FrameOptions options = const FrameOptions(fps: 2, maxFrames: 120),
    SubmissionMode mode = SubmissionMode.frames,
    PrepareDiagnostics? diag,
    CancelToken? cancel,
    List<PrepareProgress>? progress,
  }) =>
      preparer(tool).prepare(
        PrepareRequest(
          videoPath: 'v.mp4',
          dance: waltz,
          mode: mode,
          frameOptions: options,
          workDir: work,
          diagnostics: diag,
        ),
        onProgress: (p) => progress?.add(p),
        cancel: cancel ?? CancelToken(),
      );

  group('подготовка', () {
    test('кадры с метками времени, анализ музыки, сведения для разработчика',
        () async {
      final m = Metronome(bpm: 87, meter: 3, durationSec: 40);
      final tool = FakeMediaTool(audio: m.render());
      final diag = PrepareDiagnostics();
      final progress = <PrepareProgress>[];
      final r = await prepare(tool, diag: diag, progress: progress);

      expect(r.frames, hasLength(80));
      expect(r.fps, 2);
      expect(r.frames[3].timeSec, 1.5);
      expect(r.frames[3].label, 't=1.50');
      expect(tool.lastMaxLongSide, 768);
      expect(r.durationSec, 40);
      expect(r.musicAnalysis, startsWith('Темп: 87 BPM (29 тактов/мин), размер 3/4.'));

      expect(diag.hasAudio, isTrue);
      expect(diag.frameCount, 80);
      expect(diag.thinned, isFalse);
      expect(diag.previews, hasLength(6));
      expect(diag.previews.first.timeSec, 0);
      expect(diag.previews.last.timeSec, 39.5);
      expect(diag.previews.first.image.first, 32); // длинная сторона 320
      expect(diag.musicText, r.musicAnalysis);
      expect(r.musicAnalysis, contains('Уверенность анализа:'));
      expect(diag.musicLevel, isNotNull);
      expect(diag.audioRmsDb, isNotNull);
      expect(diag.musicPeriodicity, greaterThan(0.1));
      expect(diag.musicAgreement, isNotNull);
      expect(diag.stageTimes.keys, [
        PrepareStage.checkingVideo,
        PrepareStage.extractingFrames,
        PrepareStage.analyzingMusic,
      ]);
      // Звук удаляется сразу после анализа музыки.
      expect(File('${work.path}/audio.f32').existsSync(), isFalse);
      // Этапы — по порядку.
      final stages = progress.map((p) => p.stage).toList();
      expect(stages.toSet().toList(), [
        PrepareStage.checkingVideo,
        PrepareStage.extractingFrames,
        PrepareStage.analyzingMusic,
      ]);
    });

    test('нет звука → noAudio, кадры не извлекаются', () async {
      final tool = FakeMediaTool(
          info: const MediaInfo(durationSec: 30, hasAudio: false, hasVideo: true));
      await expectLater(
          prepare(tool),
          throwsA(isA<PrepareException>()
              .having((e) => e.kind, 'kind', PrepareErrorKind.noAudio)));
      expect(tool.calls, ['probe']);
    });

    test('не читается → unreadable', () async {
      await expectLater(
          prepare(FakeMediaTool(info: null)),
          throwsA(isA<PrepareException>()
              .having((e) => e.kind, 'kind', PrepareErrorKind.unreadable)));
    });

    test('ошибка декодирования кадров → unreadable', () async {
      await expectLater(
          prepare(FakeMediaTool(failFrames: true)),
          throwsA(isA<PrepareException>()
              .having((e) => e.kind, 'kind', PrepareErrorKind.unreadable)));
    });

    test('длинное видео: частота снижается под лимит, fps — фактическая',
        () async {
      final tool = FakeMediaTool(
          info: const MediaInfo(durationSec: 300, hasAudio: true, hasVideo: true));
      final diag = PrepareDiagnostics();
      final r = await prepare(tool, diag: diag);
      expect(tool.lastFps, closeTo(0.4, 1e-9));
      expect(r.fps, closeTo(0.4, 1e-9));
      expect(r.frames, hasLength(120));
      expect(r.frames[1].timeSec, closeTo(2.5, 1e-9));
      expect(diag.thinned, isTrue);
      expect(diag.requestedFps, 2);
    });

    test('длительность неизвестна: лишние кадры равномерно убираются', () async {
      final tool = FakeMediaTool(
          info: const MediaInfo(durationSec: null, hasAudio: true, hasVideo: true),
          frameCountOverride: 500);
      final r = await prepare(tool);
      expect(r.frames, hasLength(120));
      expect(r.frames.first.timeSec, 0);
      expect(r.frames.last.timeSec, 249.5);
      expect(r.fps, closeTo(120 / 250, 1e-9));
      expect(Directory('${work.path}/frames').listSync(), hasLength(120));
    });

    test('звук не извлёкся → «Анализ музыки недоступен.», без ошибки', () async {
      final r = await prepare(FakeMediaTool(failAudio: true));
      expect(r.musicAnalysis, musicAnalysisUnavailable);
      expect(r.frames, isNotEmpty);
    });

    test('ритма нет (тишина) → «Анализ музыки недоступен.»', () async {
      final diag = PrepareDiagnostics();
      final r = await prepare(FakeMediaTool(), diag: diag);
      expect(r.musicAnalysis, musicAnalysisUnavailable);
      expect(diag.notes, contains('музыка: тишина'));
      expect(diag.audioRmsDb, lessThan(-100));
    });

    test('видео целиком: кадры не извлекаются, музыка — да', () async {
      final tool = FakeMediaTool();
      final r = await prepare(tool, mode: SubmissionMode.video);
      expect(r.frames, isEmpty);
      // Облегчённая копия — в папке анализа; кадров нет.
      expect(tool.calls, ['probe', 'light', 'audio']);
      expect(r.video, isNotNull);
      expect(r.video!.path, startsWith(work.path));
    });
  });

  test('evenlySpacedIndices и planFrameRate', () {
    expect(evenlySpacedIndices(3, 6), [0, 1, 2]);
    expect(evenlySpacedIndices(11, 6), [0, 2, 4, 6, 8, 10]);
    expect(evenlySpacedIndices(5, 1), [0]);
    expect(planFrameRate(fps: 2, maxFrames: 120, durationSec: 60),
        (fps: 2.0, thinned: false));
    expect(planFrameRate(fps: 2, maxFrames: 120, durationSec: null),
        (fps: 2.0, thinned: false));
    expect(planFrameRate(fps: 2, maxFrames: 100, durationSec: 100).thinned, isTrue);
  });

  group('временные файлы удаляются в любом исходе', () {
    late TempStorage storage;
    setUp(() => storage = TempStorage(root: () async => root, isAndroid: false));

    bool workLeft() {
      final w = Directory('${root.path}/danceai_work');
      return w.existsSync() && w.listSync().isNotEmpty;
    }

    Future<AnalysisResult> run(FakeMediaTool tool, CancelToken cancel,
            [AnalysisTrace? trace]) =>
        AnalysisPipeline(
          data: data,
          preparer: preparer(tool),
          provider: _OkProvider(valid),
          tempStorage: storage,
        ).run(
          dance: waltz,
          videoPath: 'v.mp4',
          wantVideo: false,
          cancel: cancel,
          onProgress: (_) {},
          trace: trace,
        );

    test('успех', () async {
      final m = Metronome(bpm: 87, meter: 3, durationSec: 20);
      final trace = AnalysisTrace();
      await run(
          FakeMediaTool(
              audio: m.render(),
              info: const MediaInfo(
                  durationSec: 20, hasAudio: true, hasVideo: true)),
          CancelToken(),
          trace);
      expect(workLeft(), isFalse);
      expect(trace.prepare.frameCount, 40);
      expect(trace.prepare.previews, hasLength(6));
    });

    test('отмена во время извлечения кадров', () async {
      final tool = FakeMediaTool(hangOnFrames: true);
      final cancel = CancelToken();
      final future = run(tool, cancel);
      await tool.hanging.future;
      // Кадры уже лежат во временной папке.
      expect(workLeft(), isTrue);
      cancel.cancel();
      await expectLater(future, throwsA(isA<AnalysisCancelled>()));
      expect(workLeft(), isFalse);
    });

    test('отмена во время извлечения звука', () async {
      final tool = FakeMediaTool(hangOnAudio: true);
      final cancel = CancelToken();
      final future = run(tool, cancel);
      await tool.hanging.future;
      cancel.cancel();
      await expectLater(future, throwsA(isA<AnalysisCancelled>()));
      expect(workLeft(), isFalse);
    });

    test('ошибка декодирования', () async {
      await expectLater(
          run(FakeMediaTool(failFrames: true), CancelToken()),
          throwsA(isA<AnalysisFailure>()
              .having((f) => f.kind, 'kind', FailureKind.unreadableVideo)));
      expect(workLeft(), isFalse);
    });

    test('нет звука', () async {
      await expectLater(
          run(
              FakeMediaTool(
                  info: const MediaInfo(
                      durationSec: 30, hasAudio: false, hasVideo: true)),
              CancelToken()),
          throwsA(isA<AnalysisFailure>()
              .having((f) => f.kind, 'kind', FailureKind.noAudio)));
      expect(workLeft(), isFalse);
    });
  });

  test('изолят анализа музыки не захватывает объекты вызывающего (Timer, '
      'State) — как на экране анализа', () async {
    // Экран анализа держит Timer и получает прогресс через замыкание.
    final screen = _ScreenLike();
    addTearDown(screen.dispose);
    final m = Metronome(bpm: 124, meter: 4, durationSec: 30);
    final diag = PrepareDiagnostics();
    final r = await DeviceVideoPreparer(
      tool: FakeMediaTool(
          audio: m.render(),
          info: const MediaInfo(durationSec: 30, hasAudio: true, hasVideo: true)),
      thumbnailer: _fakeThumb,
    ).prepare(
      PrepareRequest(
        videoPath: 'v.mp4',
        dance: data.criteria.dance('cha_cha'),
        mode: SubmissionMode.frames,
        frameOptions: const FrameOptions(),
        workDir: work,
        diagnostics: diag,
      ),
      onProgress: screen.onProgress,
      cancel: CancelToken(),
    );
    expect(diag.notes, isEmpty);
    expect(r.musicAnalysis, startsWith('Темп: 124 BPM'));
    expect(diag.audioRmsDb, isNotNull);
    expect(screen.updates, greaterThan(0));
  });
}

class _ScreenLike {
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {});
  final controller = StreamController<PrepareProgress>.broadcast();
  var updates = 0;

  void onProgress(PrepareProgress p) {
    updates++;
    controller.add(p);
  }

  void dispose() {
    timer.cancel();
    controller.close();
  }
}
