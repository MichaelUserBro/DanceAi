import 'dart:convert';
import 'dart:io';

import 'package:dance_ai/analysis/adapter_registry.dart';
import 'package:dance_ai/analysis/ai_provider.dart';
import 'package:dance_ai/analysis/analysis_export.dart';
import 'package:dance_ai/analysis/analysis_failure.dart';
import 'package:dance_ai/analysis/analysis_pipeline.dart';
import 'package:dance_ai/analysis/cancel_token.dart';
import 'package:dance_ai/analysis/device_video_preparer.dart';
import 'package:dance_ai/analysis/media/media_tool.dart';
import 'package:dance_ai/analysis/providers/google_provider.dart';
import 'package:dance_ai/analysis/providers/http_transport.dart';
import 'package:dance_ai/analysis/providers/openai_compatible_provider.dart';
import 'package:dance_ai/analysis/stub_ai_provider.dart';
import 'package:dance_ai/analysis/temp_storage.dart';
import 'package:dance_ai/analysis/video_preparer.dart';
import 'package:dance_ai/app/app_scope.dart';
import 'package:dance_ai/app/app_version.dart';
import 'package:dance_ai/data/sha256.dart';
import 'package:dance_ai/settings/secure_key_store.dart';
import 'package:dance_ai/settings/settings_store.dart';
import 'package:dance_ai/platform/video_picker.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_http.dart';
import '../fake_media_tool.dart';
import '../metronome.dart';
import '../test_data.dart';

const _key = 'AIza-SECRET-video-mode-key-0987654321';

void main() {
  final data = loadTestAppData();
  final samba = data.criteria.dance('samba');
  // Валидный отчёт для самбы (по criteria.json) — генератор заглушки.
  final valid = jsonEncode(
      StubAiProvider(catalog: data.criteria, scenario: StubScenario.normal, seed: 1)
          .generateReport(samba, status: 'ok'));
  late Directory root;
  late TempStorage storage;

  setUp(() {
    root = Directory.systemTemp.createTempSync('danceai_vm_');
    storage = TempStorage(root: () async => root, isAndroid: false);
  });
  tearDown(() => root.deleteSync(recursive: true));

  bool workDirsLeft() {
    final work = Directory('${root.path}/danceai_work');
    return work.existsSync() && work.listSync().isNotEmpty;
  }

  HttpResult googleOk(String text) => jsonResult(200, {
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': text}
              ]
            },
            'finishReason': 'STOP'
          }
        ],
        'usageMetadata': {'promptTokenCount': 5000, 'candidatesTokenCount': 900},
      });

  // Тот же путь, что в приложении: DeviceVideoPreparer (FFmpeg подменён),
  // изолят анализа музыки, настоящий адаптер на подменённом HTTP.
  DeviceVideoPreparer preparer(FakeMediaTool tool) => DeviceVideoPreparer(
      tool: tool, thumbnailer: (img, side) async => null);
  FakeMediaTool tool({bool failLight = false, bool hangOnLight = false, int size = 4000}) =>
      FakeMediaTool(
        audio: Metronome(bpm: 100, meter: 2, durationSec: 30).render(),
        info: const MediaInfo(durationSec: 30, hasAudio: true, hasVideo: true),
        failLight: failLight,
        hangOnLight: hangOnLight,
        lightSizeBytes: size,
      );

  Future<AnalysisResult> run(AiProvider ai, FakeMediaTool t,
          {CancelToken? cancel, AnalysisTrace? trace, bool forceFrames = false,
          double fps = 2}) =>
      AnalysisPipeline(
              data: data, preparer: preparer(t), provider: ai, tempStorage: storage)
          .run(
        dance: samba,
        videoPath: 'video.mp4',
        wantVideo: true,
        forceFrames: forceFrames,
        videoFps: fps,
        cancel: cancel ?? CancelToken(),
        onProgress: (_) {},
        trace: trace,
      );

  group('режим видео (путь приложения)', () {
    test('успех: облегчённая копия создана, отправлена inline с fps, удалена; '
        'кадры не извлекались', () async {
      final t = tool();
      bool? lightExistedOnSend;
      final http = FakeHttp((c, i) {
        lightExistedOnSend = File(t.lastLightPath!).existsSync();
        return googleOk(valid);
      });
      final trace = AnalysisTrace();
      final r = await run(
          GoogleProvider(model: 'gemini-3.8-flash', apiKey: _key,
              baseUrl: 'https://g.test', transport: http),
          t, trace: trace, fps: 4);
      expect(r.report.danceId, 'samba');
      expect(t.calls, ['probe', 'light', 'audio']);
      expect(lightExistedOnSend, isTrue);
      expect(File(t.lastLightPath!).existsSync(), isFalse);
      expect(workDirsLeft(), isFalse);
      final part = (FakeHttp.body(http.calls.single)['contents'][0]['parts'] as List).first;
      expect(part['videoMetadata'], {'fps': 4.0});
      expect(trace.mode, SubmissionMode.video);
      expect(trace.videoFps, 4);
      expect(trace.prepare.lightVideoBytes, 4000);
      expect(trace.prepare.lightVideoCodec, 'fake');
      expect(trace.attempts.single.usage!.inputTokens, 5000);
      expect(trace.musicAnalysis, contains('Темп'));
    });

    test('ошибка API: копия удалена', () async {
      final t = tool();
      final http = FakeHttp((c, i) => jsonResult(400, {'error': {'message': 'boom'}}));
      await expectLater(
          run(GoogleProvider(model: 'm', apiKey: _key, baseUrl: 'https://g.test',
              transport: http), t),
          throwsA(isA<AnalysisFailure>().having((f) => f.kind, 'kind', FailureKind.server)));
      expect(File(t.lastLightPath!).existsSync(), isFalse);
      expect(workDirsLeft(), isFalse);
    });

    test('отмена во время сжатия: копия удалена', () async {
      final t = tool(hangOnLight: true);
      final cancel = CancelToken();
      final f = run(StubAiProvider(catalog: data.criteria, scenario: StubScenario.normal),
          t, cancel: cancel);
      await t.hanging.future;
      cancel.cancel();
      await expectLater(f, throwsA(isA<AnalysisCancelled>()));
      expect(workDirsLeft(), isFalse);
    });

    test('отмена во время ожидания ответа: копия удалена', () async {
      final t = tool();
      final cancel = CancelToken();
      final http = FakeHttp((c, i) async {
        cancel.cancel();
        return googleOk(valid);
      });
      await expectLater(
          run(GoogleProvider(model: 'm', apiKey: _key, baseUrl: 'https://g.test',
              transport: http), t, cancel: cancel),
          throwsA(isA<AnalysisCancelled>()));
      expect(File(t.lastLightPath!).existsSync(), isFalse);
      expect(workDirsLeft(), isFalse);
    });

    test('копия больше лимита адаптера → «Отправить кадрами», запрос не '
        'отправлен', () async {
      final t = tool(size: OpenAiCompatibleProvider.maxVideoBytes + 1);
      final http = FakeHttp((c, i) => fail('запроса быть не должно'));
      await expectLater(
          run(OpenAiCompatibleProvider(model: 'm', apiKey: _key,
              baseUrl: 'https://or.test/api/v1', transport: http), t),
          throwsA(isA<AnalysisFailure>()
              .having((f) => f.kind, 'kind', FailureKind.videoTooLarge)
              .having((f) => f.actions.first, 'action', FailureAction.sendFrames)));
      expect(workDirsLeft(), isFalse);
    });

    test('413 от сервера в режиме видео → «Отправить кадрами»', () async {
      final http = FakeHttp((c, i) => jsonResult(413, {'error': {'message': 'too big'}}));
      await expectLater(
          run(OpenAiCompatibleProvider(model: 'm', apiKey: _key,
              baseUrl: 'https://or.test/api/v1', transport: http), tool()),
          throwsA(isA<AnalysisFailure>()
              .having((f) => f.kind, 'kind', FailureKind.videoTooLarge)));
    });

    test('сжатие не удалось → «Отправить кадрами»', () async {
      await expectLater(
          run(StubAiProvider(catalog: data.criteria, scenario: StubScenario.normal),
              tool(failLight: true)),
          throwsA(isA<AnalysisFailure>()
              .having((f) => f.kind, 'kind', FailureKind.videoEncodeFailed)
              .having((f) => f.actions.first, 'action', FailureAction.sendFrames)));
      expect(workDirsLeft(), isFalse);
    });

    test('«Отправить кадрами»: тот же анализ кадрами, без копии видео', () async {
      final t = tool();
      final http = FakeHttp((c, i) => googleOk(valid));
      await run(GoogleProvider(model: 'm', apiKey: _key, baseUrl: 'https://g.test',
          transport: http), t, forceFrames: true);
      expect(t.calls, ['probe', 'frames', 'audio']);
      final parts = FakeHttp.body(http.calls.single)['contents'][0]['parts'] as List;
      expect(parts.first, {'text': 't=0.00'});
    });
  });

  group('потолок времени и настройки подачи', () {
    test('ответ не пришёл до потолка → timeLimit «Попробовать ещё раз», '
        'запрос оборван, папка удалена', () async {
      final http = FakeHttp((c, i) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return googleOk(valid);
      });
      final sw = Stopwatch()..start();
      await expectLater(
        AnalysisPipeline(
          data: data,
          preparer: preparer(tool()),
          provider: GoogleProvider(model: 'm', apiKey: _key,
              baseUrl: 'https://g.test', transport: http),
          tempStorage: storage,
          timeLimit: const Duration(milliseconds: 1500),
        ).run(
            dance: samba,
            videoPath: 'v.mp4',
            wantVideo: false,
            cancel: CancelToken(),
            onProgress: (_) {}),
        throwsA(isA<AnalysisFailure>()
            .having((f) => f.kind, 'kind', FailureKind.timeLimit)
            .having((f) => f.retryLabel, 'label', 'Попробовать ещё раз')
            .having((f) => f.actions.first, 'action', FailureAction.retry)),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 4)));
      expect(workDirsLeft(), isFalse);
    });

    test('невалидный ответ, а до потолка мало времени → повтор не '
        'запускается, timeLimit', () async {
      final http = FakeHttp((c, i) => googleOk('не JSON'));
      final trace = AnalysisTrace();
      await expectLater(
        AnalysisPipeline(
          data: data,
          preparer: preparer(tool()),
          provider: GoogleProvider(model: 'm', apiKey: _key,
              baseUrl: 'https://g.test', transport: http),
          tempStorage: storage,
          timeLimit: const Duration(seconds: 30), // < minRetryTime
        ).run(
            dance: samba,
            videoPath: 'v.mp4',
            wantVideo: false,
            cancel: CancelToken(),
            onProgress: (_) {},
            trace: trace),
        throwsA(isA<AnalysisFailure>()
            .having((f) => f.kind, 'kind', FailureKind.timeLimit)),
      );
      expect(http.calls, hasLength(1));
      expect(trace.attempts, hasLength(1));
    });

    test('«Максимум кадров» и уровень размышления доходят до запроса', () async {
      final t = tool();
      final http = FakeHttp((c, i) => googleOk(valid));
      final trace = AnalysisTrace();
      await AnalysisPipeline(
        data: data,
        preparer: preparer(t),
        provider: GoogleProvider(model: 'm', apiKey: _key,
            baseUrl: 'https://g.test', transport: http),
        tempStorage: storage,
      ).run(
          dance: samba,
          videoPath: 'v.mp4',
          wantVideo: false,
          cancel: CancelToken(),
          onProgress: (_) {},
          trace: trace,
          maxFrames: 10,
          thinkingLevel: 'low');
      final parts = FakeHttp.body(http.calls.single)['contents'][0]['parts'] as List;
      expect(parts.where((p) => p is Map && p.containsKey('inlineData')), hasLength(10));
      expect(FakeHttp.body(http.calls.single)['generationConfig']['thinkingConfig'],
          {'thinkingLevel': 'LOW'});
      expect(trace.maxFramesSetting, 10);
      final j = jsonDecode(analysisExportText(trace, data)) as Map;
      expect(j['thinking_level'], 'low');
      expect(j['max_frames_setting'], 10);
    });

    test('настройки: «Максимум кадров» по провайдеру и уровень размышления '
        'сохраняются; пусто — по умолчанию', () async {
      final prefs = MemoryPrefsStore();
      final s = SettingsStore(catalog: data.providers, prefs: prefs, keys: MemoryKeyStore());
      await s.load();
      await s.setMaxFrames('openrouter', 10);
      await s.setThinkingLevel('high');
      final again = SettingsStore(catalog: data.providers, prefs: prefs, keys: MemoryKeyStore());
      await again.load();
      expect(again.maxFramesFor('openrouter'), 10);
      expect(again.maxFramesFor('google'), isNull);
      expect(again.thinkingLevel, 'high');
      await again.setMaxFrames('openrouter', null);
      await again.setThinkingLevel(null);
      expect(again.maxFramesFor('openrouter'), isNull);
      expect(again.thinkingLevel, isNull);
    });

    test('подсказка под моделью — из providers.json', () {
      expect(data.providers.byId('google')!.modelHintRu, contains('gemini-3.6-flash'));
      expect(data.providers.byId('openrouter')!.modelHintRu, isNull);
    });
  });

  group('«Сохранить JSON»', () {
    test('содержит версии, подачу, музыку, попытки, отчёт; без ключа и промпта',
        () async {
      final t = tool();
      final http = FakeHttp((c, i) => i == 0
          ? googleOk('не JSON, ключ $_key')
          : googleOk('```json\n$valid\n```'));
      final trace = AnalysisTrace();
      await run(GoogleProvider(model: 'gemini-3.8-flash', apiKey: _key,
          baseUrl: 'https://g.test', transport: http), t, trace: trace);
      final text = analysisExportText(trace, data);
      final j = jsonDecode(text) as Map<String, dynamic>;
      expect(j['app_version'], appVersion);
      expect(j['criteria_version'], data.criteria.version);
      expect((j['content_sha256'] as Map)['prompts_and_criteria'], hasLength(64));
      expect(j['model'], 'gemini-3.8-flash');
      expect(j['dance_id'], 'samba');
      expect(j['submission']['mode'], 'video');
      expect(j['submission']['video_bytes'], 4000);
      expect(j['submission']['video_codec'], 'fake');
      expect(j['submission']['model_video_fps'], 2.0);
      expect(j['music']['text'], contains('Темп'));
      expect(j['retried'], isTrue);
      expect(j['attempts'], hasLength(2));
      expect((j['report'] as Map)['dance_id'], 'samba');
      expect(j['raw_responses'], hasLength(2));
      // Сырые ответы — как вернула модель; ключ, процитированный моделью,
      // в файл не попадает только если его нет в ответе — здесь проверяем,
      // что сами мы ключ не пишем: в запросах/сведениях его нет.
      final withoutRaw = Map.of(j)..remove('raw_responses');
      expect(jsonEncode(withoutRaw), isNot(contains(_key)));
      expect(text, isNot(contains(trace.prompt!.system)));
      expect(analysisExportFileName(trace),
          matches(RegExp(r'^danceai_samba_gemini-3\.8-flash_\d{8}-\d{6}\.json$')));
    });

    test('ошибка API с ключом в тексте сервера → ни в трассировке, ни в файле',
        () async {
      final http = FakeHttp((c, i) => jsonResult(401, {
            'error': {'message': 'API key $_key is invalid'}
          }));
      final trace = AnalysisTrace();
      await expectLater(
          run(GoogleProvider(model: 'm', apiKey: _key, baseUrl: 'https://g.test',
              transport: http), tool(), trace: trace),
          throwsA(isA<AnalysisFailure>()));
      final text = analysisExportText(trace, data);
      expect(text, isNot(contains(_key)));
      expect(trace.attempts.single.error, contains('invalidKey'));
      expect(trace.failure, isNot(contains(_key)));
    });

    test('имя файла демо-режима', () {
      final t = AnalysisTrace()
        ..danceId = 'cha_cha'
        ..demo = true
        ..startedAt = DateTime(2026, 11, 17, 9, 5, 3);
      expect(analysisExportFileName(t), 'danceai_cha_cha_demo_20261117-090503.json');
    });
  });

  test('версия приложения совпадает с pubspec.yaml', () {
    final m = RegExp(r'^version:\s*(\S+)', multiLine: true)
        .firstMatch(File('pubspec.yaml').readAsStringSync());
    expect(appVersion, m!.group(1));
  });

  test('SHA-256: известные значения', () {
    expect(sha256OfText(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(sha256OfText('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(sha256OfText('a' * 1000).length, 64);
  });

  group('настройки и выбор адаптера', () {
    late SettingsStore settings;
    late MemoryPrefsStore prefs;
    AppServices services() => AppServices(
          data: data,
          settings: settings,
          preparer: preparer(tool()),
          tempStorage: storage,
          dev: DevState(),
          videoPicker: _NoPicker(),
          transport: FakeHttp((c, i) => googleOk(valid)),
        );
    setUp(() async {
      prefs = MemoryPrefsStore();
      settings = SettingsStore(catalog: data.providers, prefs: prefs, keys: MemoryKeyStore());
      await settings.load();
    });

    test('не настроено → notConfigured; демо-режим → заглушка', () async {
      await expectLater(services().createProvider(),
          throwsA(isA<AnalysisFailure>().having((f) => f.kind, 'kind', FailureKind.notConfigured)));
      await settings.setDemoMode(true);
      expect(await services().createProvider(), isA<StubAiProvider>());
    });

    test('настроено → адаптер по типу API с адресом из каталога', () async {
      await settings.selectProvider('google');
      await settings.setModel('google', 'gemini-3.8-flash');
      await settings.saveKey('google', _key);
      final p = await services().createProvider();
      expect(p, isA<GoogleProvider>());
      expect(p.model, 'gemini-3.8-flash');
      expect((p as GoogleProvider).baseUrl, 'https://generativelanguage.googleapis.com');
    });

    test('частота видеорежима и демо-режим сохраняются', () async {
      expect(settings.videoFps, 2);
      await settings.setVideoFps(4);
      await settings.setDemoMode(true);
      await settings.setVideoFps(3); // не из списка — игнорируется
      final again = SettingsStore(catalog: data.providers, prefs: prefs, keys: MemoryKeyStore());
      await again.load();
      expect(again.videoFps, 4);
      expect(again.demoMode, isTrue);
    });

    test('пометка «не проверено вживую» — из providers.json', () {
      expect(data.providers.byId('anthropic')!.verifiedLive, isFalse);
      expect(data.providers.byId('openai')!.verifiedLive, isFalse);
      // true — только после живой проверки.
      expect(data.providers.byId('google')!.verifiedLive, isFalse);
      expect(data.providers.byId('openrouter')!.verifiedLive, isFalse);
      expect(AdapterRegistry.realAdaptersAvailable, isTrue);
    });
  });
}

class _NoPicker implements VideoPicker {
  @override
  Future<PickedVideo?> pick({required String danceId}) async => null;
  @override
  Future<RestoredPick?> takeRestored() async => null;
  @override
  Future<void> release(PickedVideo video) async {}
}
