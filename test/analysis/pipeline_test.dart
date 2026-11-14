import 'dart:convert';
import 'dart:io';

import 'package:dance_ai/analysis/ai_provider.dart';
import 'package:dance_ai/analysis/analysis_failure.dart';
import 'package:dance_ai/analysis/analysis_pipeline.dart';
import 'package:dance_ai/analysis/cancel_token.dart';
import 'package:dance_ai/analysis/stub_ai_provider.dart';
import 'package:dance_ai/analysis/temp_storage.dart';
import 'package:dance_ai/analysis/video_preparer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_data.dart';

/// Подготовка-подделка: кладёт «кадр» во временную папку, чтобы проверить,
/// что конвейер её удаляет.
class FakePreparer implements VideoPreparer {
  FakePreparer({this.error});
  final PrepareException? error;
  Directory? lastWorkDir;

  @override
  Future<VideoProbe> probe(String videoPath) async =>
      const VideoProbe(readable: true, durationSec: 30, hasAudio: true);

  @override
  Future<PreparedMaterial> prepare(PrepareRequest request,
      {required void Function(PrepareProgress) onProgress,
      required CancelToken cancel}) async {
    lastWorkDir = request.workDir;
    onProgress(const PrepareProgress(PrepareStage.checkingVideo));
    if (error != null) throw error!;
    final frame = File('${request.workDir.path}/f0.jpg')
      ..writeAsBytesSync([1, 2, 3]);
    onProgress(const PrepareProgress(PrepareStage.extractingFrames, 1));
    onProgress(const PrepareProgress(PrepareStage.analyzingMusic, 1));
    return PreparedMaterial(
      videoPath: request.videoPath,
      durationSec: 30,
      frames: [VideoFrame(timeSec: 0, path: frame.path)],
      fps: request.frameOptions.fps,
      musicAnalysis: musicAnalysisUnavailable,
    );
  }
}

/// Провайдер с заранее заданными ответами.
class ScriptedProvider implements AiProvider {
  ScriptedProvider(this.answers, {this.video = false});
  final List<Object> answers; // String или AiException
  final bool video;
  final requests = <AiRequest>[];

  @override
  String get displayName => 'Тест';

  @override
  AiCapabilities get capabilities => AiCapabilities(supportsVideo: video);

  @override
  Future<String> analyze(AiRequest request,
      {required void Function(AiPhase) onPhase,
      required CancelToken cancel}) async {
    requests.add(request);
    onPhase(AiPhase.sending);
    onPhase(AiPhase.waiting);
    final a = answers[requests.length - 1];
    if (a is AiException) throw a;
    cancel.throwIfCancelled();
    return a as String;
  }
}

void main() {
  final data = loadTestAppData();
  final waltz = data.criteria.dance('slow_waltz');
  final valid = jsonEncode(loadExampleReportJson());
  late Directory root;
  late TempStorage storage;

  setUp(() {
    root = Directory.systemTemp.createTempSync('danceai_test_');
    storage = TempStorage(root: () async => root, isAndroid: false);
  });
  tearDown(() => root.deleteSync(recursive: true));

  AnalysisPipeline pipeline(VideoPreparer p, AiProvider ai) => AnalysisPipeline(
      data: data, preparer: p, provider: ai, tempStorage: storage);

  Future<AnalysisResult> run(AnalysisPipeline p,
          {CancelToken? cancel,
          List<AnalysisStage>? stages,
          AnalysisTrace? trace,
          bool wantVideo = false}) =>
      p.run(
        dance: waltz,
        videoPath: 'video.mp4',
        wantVideo: wantVideo,
        cancel: cancel ?? CancelToken(),
        onProgress: (pr) => stages?.add(pr.stage),
        trace: trace,
      );

  bool workDirsLeft() {
    final work = Directory('${root.path}/danceai_work');
    return work.existsSync() && work.listSync().isNotEmpty;
  }

  test('успех: отчёт, все этапы по порядку, временная папка удалена', () async {
    final prep = FakePreparer();
    final stages = <AnalysisStage>[];
    final trace = AnalysisTrace();
    final result = await run(pipeline(prep, ScriptedProvider([valid])),
        stages: stages, trace: trace);
    expect(result.report.danceId, 'slow_waltz');
    expect(result.retried, isFalse);
    expect(stages.toSet().toList(), AnalysisStage.values);
    expect(prep.lastWorkDir!.existsSync(), isFalse);
    expect(workDirsLeft(), isFalse);
    expect(trace.prompt!.user, isNot(contains('{{')));
    expect(trace.responses, [valid]);
  });

  test('невалидный ответ → один повтор с описанием ошибок → успех', () async {
    final ai = ScriptedProvider(['не JSON', valid]);
    final result = await run(pipeline(FakePreparer(), ai));
    expect(result.retried, isTrue);
    expect(ai.requests, hasLength(2));
    expect(ai.requests[1].isRetry, isTrue);
    expect(ai.requests[1].retryNote, contains('Повторный запрос'));
    expect(ai.requests[1].previousResponse, 'не JSON');
  });

  test('невалидный дважды → понятная ошибка, папка удалена', () async {
    final prep = FakePreparer();
    await expectLater(
      run(pipeline(prep, ScriptedProvider(['{}', '{}']))),
      throwsA(isA<AnalysisFailure>()
          .having((f) => f.kind, 'kind', FailureKind.invalidResponse)
          .having((f) => f.details, 'details', isNotEmpty)),
    );
    expect(prep.lastWorkDir!.existsSync(), isFalse);
  });

  test('ошибка API → AnalysisFailure, без повтора, папка удалена', () async {
    final prep = FakePreparer();
    final ai = ScriptedProvider([const AiException(AiErrorKind.rateLimit)]);
    await expectLater(
      run(pipeline(prep, ai)),
      throwsA(isA<AnalysisFailure>()
          .having((f) => f.kind, 'kind', FailureKind.rateLimit)),
    );
    expect(ai.requests, hasLength(1));
    expect(prep.lastWorkDir!.existsSync(), isFalse);
  });

  test('нет звука → noAudio с действием «Выбрать другое видео»', () async {
    final prep =
        FakePreparer(error: const PrepareException(PrepareErrorKind.noAudio));
    await expectLater(
      run(pipeline(prep, ScriptedProvider([valid]))),
      throwsA(isA<AnalysisFailure>()
          .having((f) => f.kind, 'kind', FailureKind.noAudio)
          .having((f) => f.message, 'message',
              contains('В видео нет звука. Для оценки нужна музыка'))
          .having((f) => f.actions, 'actions',
              [FailureAction.chooseOtherVideo])),
    );
    expect(prep.lastWorkDir!.existsSync(), isFalse);
  });

  test('отмена → AnalysisCancelled, папка удалена', () async {
    final prep = FakePreparer();
    final cancel = CancelToken()..cancel();
    await expectLater(run(pipeline(prep, ScriptedProvider([valid])), cancel: cancel),
        throwsA(isA<AnalysisCancelled>()));
    expect(workDirsLeft(), isFalse);
  });

  test('способ подачи: видео только если включено и адаптер умеет', () async {
    for (final (want, can, expected) in [
      (false, true, SubmissionMode.frames),
      (true, false, SubmissionMode.frames),
      (true, true, SubmissionMode.video),
    ]) {
      final ai = ScriptedProvider([valid], video: can);
      await run(pipeline(FakePreparer(), ai), wantVideo: want);
      expect(ai.requests.single.mode, expected);
    }
  });

  test('сквозной прогон с заглушкой для всех танцев', () async {
    for (final dance in data.criteria.dances) {
      final ai = StubAiProvider(
          catalog: data.criteria,
          scenario: StubScenario.normal,
          minDelay: Duration.zero,
          maxDelay: Duration.zero);
      final result = await pipeline(FakePreparer(), ai).run(
        dance: dance,
        videoPath: 'v.mp4',
        wantVideo: false,
        cancel: CancelToken(),
        onProgress: (_) {},
      );
      expect(result.report.danceId, dance.id);
    }
  });
}
