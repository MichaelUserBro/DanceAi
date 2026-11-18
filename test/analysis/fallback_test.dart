// Повторы при перегрузке и запасные модели (spec 7.7): конвейер на
// записанных исходах попыток — без сети и без настоящих пауз.
import 'dart:convert';
import 'dart:io';

import 'package:dance_ai/analysis/ai_provider.dart';
import 'package:dance_ai/analysis/analysis_export.dart';
import 'package:dance_ai/analysis/analysis_failure.dart';
import 'package:dance_ai/analysis/analysis_pipeline.dart';
import 'package:dance_ai/analysis/cancel_token.dart';
import 'package:dance_ai/analysis/media/media_tool.dart';
import 'package:dance_ai/analysis/quota_time.dart';
import 'package:dance_ai/analysis/temp_storage.dart';
import 'package:dance_ai/analysis/video_preparer.dart';
import 'package:dance_ai/data/providers_catalog.dart';
import 'package:dance_ai/report/overall_score.dart';
import 'package:dance_ai/report/report.dart';
import 'package:dance_ai/ui/screens/analysis_screen.dart' show noticeText;
import 'package:flutter_test/flutter_test.dart';

import '../test_data.dart';

const _overloaded =
    AiException(AiErrorKind.overloaded, 'HTTP 503: UNAVAILABLE: high demand');
const _quota = AiException(AiErrorKind.rateLimit, 'HTTP 429: RESOURCE_EXHAUSTED');

/// Кадры или облегчённая копия во временной папке анализа.
class _Preparer implements VideoPreparer {
  @override
  Future<VideoProbe> probe(String videoPath) async =>
      const VideoProbe(readable: true, durationSec: 30, hasAudio: true);

  @override
  Future<PreparedMaterial> prepare(PrepareRequest request,
      {required void Function(PrepareProgress) onProgress,
      required CancelToken cancel}) async {
    final dir = request.workDir.path;
    if (request.mode == SubmissionMode.video) {
      final light = File('$dir/light.mp4')..writeAsBytesSync([1, 2, 3]);
      return PreparedMaterial(
        videoPath: request.videoPath,
        durationSec: 30,
        frames: const [],
        fps: 0,
        musicAnalysis: musicAnalysisUnavailable,
        video: LightVideo(path: light.path, sizeBytes: 3, codec: 'fake'),
      );
    }
    final frame = File('$dir/f0.jpg')..writeAsBytesSync([1, 2, 3]);
    return PreparedMaterial(
      videoPath: request.videoPath,
      durationSec: 30,
      frames: [VideoFrame(timeSec: 0, path: frame.path)],
      fps: 1,
      musicAnalysis: musicAnalysisUnavailable,
    );
  }
}

/// Отправлено, ответ не начинается, пока попытку не прервут.
class _Silent {
  const _Silent();
}

/// Отправлено; ответ [text] через [after]. [started] — первые байты потока
/// приходят сразу (модель начала отвечать), иначе — только в конце.
class _Late {
  const _Late(this.text, this.after, {this.started = false});
  final String text;
  final Duration after;
  final bool started;
}

/// Исходы попыток по моделям: String — ответ, AiException — ошибка,
/// [_Silent] / [_Late] — ожидание ответа. [streams] — адаптер отвечает потоком.
class _Models {
  _Models(this.script, {this.streams = false});
  final Map<String, List<Object>> script;
  final bool streams;
  final calls = <(String model, AiRequest request)>[];

  _Provider provider(String model) => _Provider(this, model);
}

class _Provider implements AiProvider {
  _Provider(this.models, this.model);
  final _Models models;

  @override
  final String model;

  @override
  String get displayName => 'Тест';

  @override
  AiCapabilities get capabilities =>
      AiCapabilities(supportsVideo: true, streamsResponse: models.streams);

  @override
  Future<ModelLookup?> lookupModel(CancelToken cancel) async => null;

  @override
  Future<AiResponse> analyze(AiRequest request,
      {required void Function(AiProgress) onProgress,
      required CancelToken cancel}) async {
    models.calls.add((model, request));
    final n = models.calls.where((c) => c.$1 == model).length;
    final outcomes = models.script[model] ?? const [];
    if (n > outcomes.length) fail('лишний запрос к $model');
    final a = outcomes[n - 1];
    if (a is AiException) throw a.withInfo(sentBytes: 100);
    onProgress(const AiProgress(AiPhase.sending, 0));
    onProgress(const AiProgress(AiPhase.waiting));
    if (a is _Silent) {
      await cancel.whenCancelled;
      throw const AnalysisCancelled();
    }
    if (a is _Late) {
      if (a.started) onProgress(const AiProgress(AiPhase.waiting, null, 10));
      await Future.any([Future<void>.delayed(a.after), cancel.whenCancelled]);
      cancel.throwIfCancelled();
      return AiResponse(text: a.text, sentBytes: 100);
    }
    return AiResponse(text: a as String, sentBytes: 100);
  }
}

void main() {
  final data = loadTestAppData();
  final waltz = data.criteria.dance('slow_waltz');
  final valid = jsonEncode(loadExampleReportJson());
  late Directory root;
  late TempStorage storage;

  setUp(() {
    root = Directory.systemTemp.createTempSync('danceai_fb_');
    storage = TempStorage(root: () async => root, isAndroid: false);
  });
  tearDown(() => root.deleteSync(recursive: true));

  const both = {'frames', 'video'};
  const fallbacks = [
    FallbackModel(id: 'main', modes: both), // совпадает с основной — пропуск
    FallbackModel(id: 'fb1', modes: both),
    FallbackModel(id: 'fb2', modes: both),
  ];

  ({AnalysisPipeline pipeline, List<Duration> pauses}) make(
    _Models m, {
    List<FallbackModel> fb = fallbacks,
    Duration timeLimit = analysisTimeLimit,
    Duration slowOverload = slowOverloadThreshold,
    Duration startLimit = const Duration(milliseconds: 100),
    Duration startReserve = fallbackReserve,
    bool realPause = false,
  }) {
    final pauses = <Duration>[];
    final p = AnalysisPipeline(
      data: data,
      preparer: _Preparer(),
      provider: m.provider('main'),
      tempStorage: storage,
      fallbackModels: fb,
      providerFor: m.provider,
      useFallbackModels: fb.isNotEmpty,
      overloadHintRu: 'квота Google обновляется в {{pacific_midnight_msk}} МСК',
      timeLimit: timeLimit,
      slowOverload: slowOverload,
      startLimit: startLimit,
      startReserve: startReserve,
      pause: realPause
          ? null
          : (d, c) async {
              pauses.add(d);
              c.throwIfCancelled();
            },
    );
    return (pipeline: p, pauses: pauses);
  }

  Future<AnalysisResult> run(AnalysisPipeline p,
          {AnalysisTrace? trace,
          List<AnalysisProgress>? progress,
          CancelToken? cancel,
          bool video = false}) =>
      p.run(
        dance: waltz,
        videoPath: 'video.mp4',
        wantVideo: video,
        cancel: cancel ?? CancelToken(),
        onProgress: (pr) => progress?.add(pr),
        trace: trace,
      );

  Matcher failure(FailureKind kind) =>
      throwsA(isA<AnalysisFailure>().having((f) => f.kind, 'kind', kind));

  test('503 сразу → пауза 5 с → повтор той же модели → успех', () async {
    final m = _Models({'main': [_overloaded, valid]});
    final x = make(m);
    final trace = AnalysisTrace();
    final progress = <AnalysisProgress>[];
    final r = await run(x.pipeline, trace: trace, progress: progress);
    expect(m.calls.map((c) => c.$1), ['main', 'main']);
    expect(x.pauses, [const Duration(seconds: 5)]);
    expect(r.fallbackModel, isNull);
    expect([for (final a in trace.attempts) a.reason],
        [AttemptReason.first, AttemptReason.overloaded]);
    expect(trace.attempts[1].pause, const Duration(seconds: 5));
    expect(trace.attempts.first.sentBytes, 100);
    expect(trace.answeredModel, 'main');
    final n = progress.map((p) => p.notice).nonNulls.single;
    expect((n.reason, n.model, n.nextModel),
        (AttemptReason.overloaded, 'main', null));
  });

  test('503 ×2 на основной → запасная → успех; строка для отчёта', () async {
    final m = _Models({
      'main': [_overloaded, _overloaded],
      'fb1': [valid],
    });
    final x = make(m);
    final trace = AnalysisTrace();
    final progress = <AnalysisProgress>[];
    final r = await run(x.pipeline, trace: trace, progress: progress);
    expect(m.calls.map((c) => c.$1), ['main', 'main', 'fb1']);
    expect(r.requestedModel, 'main');
    expect(r.fallbackModel, 'fb1');
    expect(trace.modelChain, ['main', 'fb1', 'fb2']);
    expect(trace.answeredModel, 'fb1');
    expect(trace.attempts.last.model, 'fb1');
    final notices = progress.map((p) => p.notice).nonNulls.toList();
    expect(notices.last.nextModel, 'fb1');
    final json = analysisExport(trace, data);
    expect(json['requested_model'], 'main');
    expect(json['answered_model'], 'fb1');
    expect(json['use_fallback_models'], isTrue);
    final attempts = json['attempts'] as List;
    expect((attempts.last as Map)['model'], 'fb1');
    expect((attempts.last as Map)['reason'], 'overloaded');
    expect((attempts[1] as Map)['pause_ms'], 5000);
    final ids = [for (final c in data.criteria.components) c.id];
    expect(json['overall_score'],
        overallScore(DanceReport.fromJson(loadExampleReportJson()), ids));
    expect(json['overall_score'], isA<double>());
  });

  test('медленный 503 → сразу запасная, без повтора той же', () async {
    final m = _Models({
      'main': [_overloaded],
      'fb1': [valid],
    });
    final x = make(m, slowOverload: Duration.zero);
    final r = await run(x.pipeline);
    expect(m.calls.map((c) => c.$1), ['main', 'fb1']);
    expect(x.pauses, isEmpty);
    expect(r.fallbackModel, 'fb1');
  });

  test('429 на основной → запасная, без повтора той же', () async {
    final m = _Models({
      'main': [_quota],
      'fb1': [valid],
    });
    final x = make(m);
    final trace = AnalysisTrace();
    final r = await run(x.pipeline, trace: trace);
    expect(m.calls.map((c) => c.$1), ['main', 'fb1']);
    expect(x.pauses, isEmpty);
    expect(r.fallbackModel, 'fb1');
    expect(trace.attempts.last.reason, AttemptReason.rateLimit);
  });

  test('запасная недоступна (404) → следующая', () async {
    final m = _Models({
      'main': [_quota],
      'fb1': [const AiException(AiErrorKind.modelUnavailable, 'HTTP 404')],
      'fb2': [valid],
    });
    final r = await run(make(m).pipeline);
    expect(r.fallbackModel, 'fb2');
  });

  test('всё исчерпано → «Сервер ИИ перегружен» с временем сброса квоты',
      () async {
    final m = _Models({
      'main': [_overloaded, _overloaded],
      'fb1': [_overloaded, _quota],
      'fb2': [_quota],
    });
    final x = make(m);
    final trace = AnalysisTrace();
    AnalysisFailure? f;
    try {
      await run(x.pipeline, trace: trace);
    } on AnalysisFailure catch (e) {
      f = e;
    }
    expect(f!.kind, FailureKind.overloaded);
    expect(f.title, 'Сервер ИИ перегружен');
    expect(f.message, contains('На бесплатном тарифе такое бывает'));
    expect(f.message, contains('квота Google обновляется в ${pacificMidnightMsk()} МСК'));
    expect(f.actions.first, FailureAction.retry);
    expect(f.retryLabel, 'Попробовать ещё раз');
    expect(m.calls.map((c) => c.$1), ['main', 'main', 'fb1', 'fb1', 'fb2']);
    expect(x.pauses, const [Duration(seconds: 5), Duration(seconds: 10)]);
    expect(trace.failure, startsWith('overloaded'));
  });

  test('только 429 везде → «Лимит запросов», не «перегружен»', () async {
    final m = _Models({
      'main': [_quota],
      'fb1': [_quota],
      'fb2': [_quota],
    });
    await expectLater(run(make(m).pipeline), failure(FailureKind.rateLimit));
  });

  test('не хватает времени до потолка → новая попытка не начинается',
      () async {
    final m = _Models({'main': [_overloaded]});
    // Повтор требует 60 с + пауза 5 с, а потолок — 50 с.
    final x = make(m, timeLimit: const Duration(seconds: 50));
    await expectLater(run(x.pipeline), failure(FailureKind.overloaded));
    expect(m.calls, hasLength(1));
    expect(x.pauses, isEmpty);
  });

  test('отмена во время паузы — сразу, без следующего запроса', () async {
    final m = _Models({'main': [_overloaded, valid]});
    final x = make(m, realPause: true);
    final cancel = CancelToken();
    final progress = <AnalysisProgress>[];
    final sw = Stopwatch()..start();
    final f = run(x.pipeline, cancel: cancel, progress: progress);
    // Ждём начала паузы (после уведомления о повторе) и отменяем.
    while (progress.every((p) => p.notice == null)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    cancel.cancel();
    await expectLater(f, throwsA(isA<AnalysisCancelled>()));
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    expect(m.calls, hasLength(1));
  });

  test('ошибка ключа — без повторов и без цепочки', () async {
    final m = _Models({
      'main': [const AiException(AiErrorKind.invalidKey, 'HTTP 401')],
    });
    await expectLater(run(make(m).pipeline), failure(FailureKind.invalidKey));
    expect(m.calls, hasLength(1));
  });

  test('сеть и размер — без цепочки', () async {
    for (final (e, kind) in [
      (const AiException(AiErrorKind.network, 'SocketException'), FailureKind.network),
      (const AiException(AiErrorKind.tooLarge, 'HTTP 413'), FailureKind.tooLarge),
    ]) {
      final m = _Models({'main': [e]});
      await expectLater(run(make(m).pipeline), failure(kind));
      expect(m.calls, hasLength(1));
    }
  });

  test('модель пользователя не найдена (404) — понятная ошибка, без цепочки',
      () async {
    final m = _Models({
      'main': [const AiException(AiErrorKind.modelUnavailable, 'HTTP 404')],
    });
    await expectLater(
        run(make(m).pipeline), failure(FailureKind.modelUnavailable));
    expect(m.calls, hasLength(1));
  });

  test('режим видео без подходящей запасной → «Отправить кадрами»', () async {
    final m = _Models({'main': [_overloaded, _overloaded]});
    final x = make(m, fb: const [
      FallbackModel(id: 'frames-only', modes: {'frames'}),
    ]);
    final trace = AnalysisTrace();
    AnalysisFailure? f;
    try {
      await run(x.pipeline, trace: trace, video: true);
    } on AnalysisFailure catch (e) {
      f = e;
    }
    expect(trace.mode, SubmissionMode.video);
    expect(trace.modelChain, ['main']);
    expect(f!.kind, FailureKind.overloaded);
    expect(f.framesFallback, isTrue);
    expect(f.actions.first, FailureAction.sendFrames);
    expect(m.calls.map((c) => c.$1), ['main', 'main']);
  });

  test('запасные выключены → только повтор той же модели', () async {
    final m = _Models({'main': [_overloaded, _overloaded]});
    final x = make(m, fb: const []);
    final trace = AnalysisTrace();
    await expectLater(run(x.pipeline, trace: trace), failure(FailureKind.overloaded));
    expect(trace.useFallbackModels, isFalse);
    expect(analysisExport(trace, data)['use_fallback_models'], isFalse);
    expect(analysisExport(trace, data)['overall_score'], isNull);
    expect(m.calls, hasLength(2));
  });

  test('невалидный JSON: исправляющий повтор, затем 503 → запасная получает '
      'исходный запрос', () async {
    final m = _Models({
      'main': ['не JSON', _overloaded, _overloaded],
      'fb1': [valid],
    });
    final trace = AnalysisTrace();
    final r = await run(make(m).pipeline, trace: trace);
    expect(r.fallbackModel, 'fb1');
    expect(m.calls[1].$2.isRetry, isTrue);
    expect(m.calls.last.$2.isRetry, isFalse);
    expect([for (final a in trace.attempts) a.reason], [
      AttemptReason.first,
      AttemptReason.invalidResponse,
      AttemptReason.overloaded,
      AttemptReason.overloaded,
    ]);
  });

  test('невалидный JSON дважды — понятная ошибка (повтор один на анализ)',
      () async {
    final m = _Models({'main': ['{}', '{}']});
    await expectLater(
        run(make(m).pipeline), failure(FailureKind.invalidResponse));
  });

  group('ответ не начинается (spec 7.7)', () {
    const slow = Duration(milliseconds: 400);

    test('предел ожидания начала ответа → запасная, без повтора той же',
        () async {
      final m = _Models({
        'main': [const _Silent()],
        'fb1': [valid],
      }, streams: true);
      final x = make(m);
      final trace = AnalysisTrace();
      final progress = <AnalysisProgress>[];
      final r = await run(x.pipeline, trace: trace, progress: progress);
      expect(m.calls.map((c) => c.$1), ['main', 'fb1']);
      expect(x.pauses, isEmpty);
      expect(r.fallbackModel, 'fb1');
      expect([for (final a in trace.attempts) a.reason],
          [AttemptReason.first, AttemptReason.noResponse]);
      expect(trace.attempts.first.error, startsWith('noResponse'));
      expect(trace.attempts.first.notes.single, contains('нет ответа'));
      final n = progress.map((p) => p.notice).nonNulls.single;
      expect(noticeText(n), 'Модель main не отвечает, пробую запасную: fb1…');
      final attempts = analysisExport(trace, data)['attempts'] as List;
      expect((attempts.last as Map)['reason'], 'noResponse');
    });

    test('модель начала отвечать — предел не прерывает', () async {
      final m = _Models({
        'main': [_Late(valid, slow, started: true)],
      }, streams: true);
      final r = await run(make(m).pipeline);
      expect(r.fallbackModel, isNull);
      expect(m.calls, hasLength(1));
    });

    test('нет следующей модели — предела нет, ждём ответа', () async {
      // Запасные выключены.
      final m1 = _Models({'main': [_Late(valid, slow)]}, streams: true);
      expect((await run(make(m1, fb: const []).pipeline)).fallbackModel,
          isNull);
      // Последняя модель цепочки.
      final m2 = _Models({
        'main': [_quota],
        'fb1': [_Late(valid, slow)],
      }, streams: true);
      final r = await run(make(m2, fb: const [
        FallbackModel(id: 'fb1', modes: both),
      ]).pipeline);
      expect(r.fallbackModel, 'fb1');
    });

    test('адаптер без потока — предела нет', () async {
      final m = _Models({'main': [_Late(valid, slow)]});
      final r = await run(make(m).pipeline);
      expect(r.fallbackModel, isNull);
      expect(m.calls, hasLength(1));
    });

    test('до потолка уже меньше резерва — не прерываем', () async {
      final m = _Models({'main': [_Late(valid, slow)]}, streams: true);
      final r = await run(
          make(m, startReserve: analysisTimeLimit).pipeline);
      expect(r.fallbackModel, isNull);
    });

    test('обрыв до заголовков (noResponse) → запасная', () async {
      final m = _Models({
        'main': [
          const AiException(AiErrorKind.noResponse,
              'HttpException: Connection closed before full header was received'),
        ],
        'fb1': [valid],
      });
      final x = make(m);
      final trace = AnalysisTrace();
      final r = await run(x.pipeline, trace: trace);
      expect(r.fallbackModel, 'fb1');
      expect(x.pauses, isEmpty);
      expect(trace.attempts.last.reason, AttemptReason.noResponse);
    });

    test('обрыв до заголовков без запасных → «перегружен», не ошибка сети',
        () async {
      final m = _Models({
        'main': [const AiException(AiErrorKind.noResponse, 'closed')],
      });
      final trace = AnalysisTrace();
      await expectLater(run(make(m, fb: const []).pipeline, trace: trace),
          failure(FailureKind.overloaded));
      expect(m.calls, hasLength(1));
      expect(trace.failure, contains('сервер не начал отвечать'));
    });
  });

  group('providers.json: fallback_models', () {
    final json = jsonDecode(File('assets/providers.json').readAsStringSync())
        as Map<String, dynamic>;
    test('структура: id, режимы frames/video, без дублей', () {
      for (final p in json['providers'] as List) {
        final list = (p as Map)['fallback_models'];
        if (list == null) continue;
        expect(list, isA<List>(), reason: '${p['id']}');
        final ids = <String>{};
        for (final f in list as List) {
          final m = f as Map;
          expect(m.keys.toSet(), {'id', 'modes'}, reason: '$m');
          expect(m['id'], isA<String>());
          expect((m['id'] as String).trim(), isNotEmpty);
          expect(ids.add(m['id'] as String), isTrue, reason: 'дубль ${m['id']}');
          final modes = (m['modes'] as List).cast<String>();
          expect(modes, isNotEmpty);
          expect(FallbackModel.knownModes.containsAll(modes), isTrue,
              reason: '$modes');
        }
      }
    });

    test('у Google есть запасные модели и подсказка с временем квоты', () {
      final google = data.providers.byId('google')!;
      expect(google.fallbackModels, isNotEmpty);
      expect(google.overloadHintRu, contains('{{pacific_midnight_msk}}'));
      for (final f in google.fallbackModels) {
        expect(f.modes, contains('frames'), reason: f.id);
      }
    });
  });

  group('время сброса квоты (полночь по Тихоокеанскому → МСК)', () {
    test('зима — 11:00, лето — 10:00', () {
      expect(pacificMidnightMsk(DateTime.utc(2026, 11, 17, 12)), '11:00');
      expect(pacificMidnightMsk(DateTime.utc(2026, 1, 10, 12)), '11:00');
      expect(pacificMidnightMsk(DateTime.utc(2026, 7, 1, 12)), '10:00');
    });

    test('дни перехода: 8 марта и 1 ноября 2026', () {
      // Полночь 8.03 (день перехода) ещё зимняя, 9.03 — уже летняя.
      expect(pacificMidnightMsk(DateTime.utc(2026, 3, 7, 12)), '11:00');
      expect(pacificMidnightMsk(DateTime.utc(2026, 3, 8, 12)), '10:00');
      // Полночь 1.11 ещё летняя, 2.11 — уже зимняя.
      expect(pacificMidnightMsk(DateTime.utc(2026, 10, 31, 12)), '10:00');
      expect(pacificMidnightMsk(DateTime.utc(2026, 11, 1, 12)), '11:00');
    });

    test('подстановка в подсказку', () {
      expect(fillQuotaHint('в {{pacific_midnight_msk}} МСК',
          DateTime.utc(2026, 7, 1)), 'в 10:00 МСК');
    });
  });
}
