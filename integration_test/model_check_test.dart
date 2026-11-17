// ЖИВАЯ проверка запасных моделей — только по команде автора (тратит лимиты).
// Для каждой модели — маленький запрос кадрами (2 кадра) и видео (облегчённая
// копия) с ответом-JSON `{"ok": true, "saw": "…"}` через настоящий адаптер
// (поток SSE, упрощённая схема). Ключ — из переменной окружения провайдера,
// никуда не выводится и не записывается.
//
//   flutter test integration_test/model_check_test.dart -d windows ^
//     --dart-define=LIVE=1 ^
//     --dart-define=CHECK_PROVIDER=google ^
//     --dart-define=CHECK_MODELS=gemini-4-hydrogen,gemini-3.5-flash-lite ^
//     --dart-define=CHECK_MODES=frames,video ^
//     --dart-define=CHECK_VIDEO=samba_1
//
// CHECK_MODELS пусто — все fallback_models
// провайдера из providers.json. Между запросами — пауза CHECK_PAUSE_S (4 с).
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:dance_ai/analysis/adapter_registry.dart';
import 'package:dance_ai/analysis/ai_provider.dart';
import 'package:dance_ai/analysis/cancel_token.dart';
import 'package:dance_ai/analysis/device_video_preparer.dart';
import 'package:dance_ai/analysis/providers/http_transport.dart';
import 'package:dance_ai/analysis/video_preparer.dart';
import 'package:dance_ai/data/app_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _live = String.fromEnvironment('LIVE');
const _providerId = String.fromEnvironment('CHECK_PROVIDER', defaultValue: 'google');
const _models = String.fromEnvironment('CHECK_MODELS');
const _modes = String.fromEnvironment('CHECK_MODES', defaultValue: 'frames,video');
const _video = String.fromEnvironment('CHECK_VIDEO', defaultValue: 'samba_1');
const _pauseS = int.fromEnvironment('CHECK_PAUSE_S', defaultValue: 4);
const _videoDir = String.fromEnvironment('VIDEO_DIR', defaultValue: 'test_videos');

const _envKeys = {
  'google': 'DANCEAI_GOOGLE_KEY',
  'openrouter': 'DANCEAI_OPENROUTER_KEY',
};

const _schema = {
  'type': 'object',
  'required': ['ok', 'saw'],
  'properties': {
    'ok': {'type': 'boolean'},
    'saw': {'type': 'string'},
  },
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('живая проверка моделей', (tester) async {
    if (_live != '1') {
      print('CHECK пропущено: нужен --dart-define=LIVE=1');
      return;
    }
    final key = Platform.environment[_envKeys[_providerId] ?? ''];
    if (key == null || key.isEmpty) {
      print('CHECK пропущено: нет ${_envKeys[_providerId]}');
      return;
    }
    final data = await AppData.load();
    final provider = data.providers.byId(_providerId)!;
    final models = _models.isEmpty
        ? [for (final f in provider.fallbackModels) f.id]
        : _models.split(',');
    final file = Directory(_videoDir)
        .listSync()
        .whereType<File>()
        .firstWhere((f) => f.uri.pathSegments.last.startsWith(_video));
    final dance = data.criteria.dance('samba');
    final preparer = DeviceVideoPreparer();
    final transport = IoHttpTransport();

    // Материал готовим один раз на режим.
    final work = await Directory.systemTemp.createTemp('danceai_check_');
    addTearDown(() => work.delete(recursive: true));
    final material = <SubmissionMode, PreparedMaterial>{};
    for (final mode in _modes.split(',')) {
      final m = SubmissionMode.values.byName(mode);
      final dir = await Directory('${work.path}/$mode').create();
      material[m] = await tester.runAsync(() => preparer.prepare(
            PrepareRequest(
              videoPath: file.path,
              dance: dance,
              mode: m,
              frameOptions: const FrameOptions(fps: 0.1, maxFrames: 2),
              workDir: dir,
            ),
            onProgress: (_) {},
            cancel: CancelToken(),
          )) as PreparedMaterial;
    }

    print('CHECK | модель | режим | итог | с | HTTP | заголовки, с | '
        'первый байт, с | отправлено | токены (вход/выход/размышл.) | ответ');
    var first = true;
    for (final model in models) {
      for (final MapEntry(key: mode, value: m) in material.entries) {
        if (!first) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(seconds: _pauseS)));
        }
        first = false;
        final ai = AdapterRegistry.create(
          provider: provider,
          model: model,
          apiKey: key,
          baseUrl: provider.baseUrl,
          transport: transport,
        );
        final request = AiRequest(
          danceId: 'samba',
          systemPrompt: 'Это проверка доступа к API. Отвечай только JSON.',
          userPrompt: 'Ответь строго JSON-объектом {"ok": true, "saw": "<что '
              'видно на материале, 3–6 слов по-русски>"}.',
          mode: mode,
          material: m,
          reportSchema: _schema,
        );
        final sw = Stopwatch()..start();
        String sec(Duration? d) =>
            d == null ? '—' : (d.inMilliseconds / 1000).toStringAsFixed(1);
        // runAsync проглатывает исключения — исход ловим внутри.
        final outcome = await tester.runAsync<Object>(() async {
          try {
            return await ai.analyze(request,
                onProgress: (_) {}, cancel: CancelToken());
          } on AiException catch (e) {
            return e;
          }
        });
        try {
          if (outcome is AiException) throw outcome;
          final r = outcome! as AiResponse;
          final j = jsonDecode(r.text);
          final ok = j is Map && j['ok'] == true;
          final u = r.usage;
          print('CHECK | $model | ${mode.name} | ${ok ? 'OK' : 'не тот JSON'} | '
              '${sec(sw.elapsed)} | ${r.diag?.status} | ${sec(r.diag?.headersTime)} | '
              '${sec(r.diag?.firstByteTime)} | ${r.sentBytes} | '
              '${u?.inputTokens}/${u?.outputTokens}/${u?.thinkingTokens} | '
              '${j is Map ? j['saw'] : r.text}'
              '${r.notes.isEmpty ? '' : ' | ${r.notes.join('; ')}'}');
        } on AiException catch (e) {
          print('CHECK | $model | ${mode.name} | ${e.kind.name} | ${sec(sw.elapsed)} | '
              '${e.diag?.status} | ${sec(e.diag?.headersTime)} | '
              '${sec(e.diag?.firstByteTime)} | ${e.sentBytes} | — | '
              '${e.detail}${e.notes.isEmpty ? '' : ' | ${e.notes.join('; ')}'}'
              '${e.diag?.errorSource == null ? '' : ' (из ${e.diag!.errorSource!.name})'}');
          expect('${e.detail}', isNot(contains(key)));
        } on FormatException {
          print('CHECK | $model | ${mode.name} | ответ не JSON | ${sec(sw.elapsed)}');
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 60)));
}
