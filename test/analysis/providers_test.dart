import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dance_ai/analysis/adapter_registry.dart';
import 'package:dance_ai/analysis/ai_provider.dart';
import 'package:dance_ai/analysis/analysis_failure.dart';
import 'package:dance_ai/analysis/cancel_token.dart';
import 'package:dance_ai/analysis/media/media_tool.dart';
import 'package:dance_ai/analysis/providers/anthropic_provider.dart';
import 'package:dance_ai/analysis/providers/google_provider.dart';
import 'package:dance_ai/analysis/providers/http_ai_provider.dart';
import 'package:dance_ai/analysis/providers/http_transport.dart';
import 'package:dance_ai/analysis/providers/openai_compatible_provider.dart';
import 'package:dance_ai/analysis/providers/openai_provider.dart';
import 'package:dance_ai/analysis/providers/provider_common.dart';
import 'package:dance_ai/analysis/video_preparer.dart';
import 'package:dance_ai/data/providers_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_http.dart';

const _key = 'sk-SECRET-test-key-1234567890';
const _report = '{"dance_id": "samba"}';

void main() {
  late Directory dir;
  late PreparedMaterial frames;
  late PreparedMaterial video;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('danceai_prov_');
    final f1 = File('${dir.path}/f_00001.jpg')..writeAsBytesSync([1, 2, 3]);
    final f2 = File('${dir.path}/f_00002.jpg')..writeAsBytesSync([4, 5, 6]);
    final light = File('${dir.path}/light.mp4')..writeAsBytesSync(List.filled(30, 9));
    frames = PreparedMaterial(
      videoPath: 'v.mp4',
      durationSec: 1,
      frames: [
        VideoFrame(timeSec: 0, path: f1.path),
        VideoFrame(timeSec: 12.5, path: f2.path),
      ],
      fps: 2,
      musicAnalysis: 'Темп: 100 BPM',
    );
    video = PreparedMaterial(
      videoPath: 'v.mp4',
      durationSec: 1,
      frames: const [],
      fps: 2,
      musicAnalysis: 'Темп: 100 BPM',
      video: LightVideo(path: light.path, sizeBytes: 30, codec: 'h264_mf'),
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  AiRequest req(PreparedMaterial m, {bool retry = false, double fps = 2}) {
    final r = AiRequest(
      danceId: 'samba',
      systemPrompt: 'SYSTEM',
      userPrompt: 'USER',
      mode: m.video != null ? SubmissionMode.video : SubmissionMode.frames,
      material: m,
      reportSchema: const {},
      videoFps: fps,
    );
    return retry ? r.retry(note: 'RETRY NOTE', previous: 'PREVIOUS') : r;
  }

  Future<AiResponse> analyze(AiProvider p, AiRequest r,
          {CancelToken? cancel, List<AiProgress>? progress}) =>
      p.analyze(r,
          onProgress: (x) => progress?.add(x), cancel: cancel ?? CancelToken());

  // Ответы разных API с текстом отчёта.
  HttpResult googleOk(String text) => jsonResult(200, {
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'размышления', 'thought': true},
                {'text': text},
              ]
            },
            'finishReason': 'STOP',
          }
        ],
        'usageMetadata': {
          'promptTokenCount': 1000,
          'candidatesTokenCount': 200,
          'thoughtsTokenCount': 50,
        },
      });
  HttpResult chatOk(String text) => jsonResult(200, {
        'choices': [
          {
            'message': {'role': 'assistant', 'content': text},
            'finish_reason': 'stop',
          }
        ],
        'usage': {
          'prompt_tokens': 10,
          'completion_tokens': 20,
          'completion_tokens_details': {'reasoning_tokens': 5},
        },
      });
  HttpResult anthropicOk(String text) => jsonResult(200, {
        'content': [
          {'type': 'text', 'text': text}
        ],
        'stop_reason': 'end_turn',
        'usage': {'input_tokens': 7, 'output_tokens': 8},
      });
  HttpResult openaiOk(String text) => jsonResult(200, {
        'status': 'completed',
        'output': [
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': text}
            ]
          }
        ],
        'usage': {
          'input_tokens': 3,
          'output_tokens': 4,
          'output_tokens_details': {'reasoning_tokens': 1},
        },
      });

  GoogleProvider google(FakeHttp http, {int inlineMax = 1000}) => GoogleProvider(
      model: 'gemini-3.8-flash',
      apiKey: _key,
      baseUrl: 'https://g.test',
      transport: http,
      inlineVideoMaxBytes: inlineMax,
      pollInterval: const Duration(milliseconds: 1));
  OpenAiCompatibleProvider compat(FakeHttp http, {String model = 'nvidia/x:free'}) =>
      OpenAiCompatibleProvider(
          model: model, apiKey: _key, baseUrl: 'https://or.test/api/v1/', transport: http);
  AnthropicProvider anthropic(FakeHttp http) => AnthropicProvider(
      model: 'claude-haiku-5-5', apiKey: _key, baseUrl: 'https://a.test', transport: http);
  OpenAiProvider openai(FakeHttp http) => OpenAiProvider(
      model: 'gpt-6.1-terra', apiKey: _key, baseUrl: 'https://o.test/v1', transport: http);

  /// Все адаптеры с одинаковым успешным ответом — для общих проверок.
  Map<String, HttpAiProvider Function(FakeHttp)> all = {};
  Map<String, HttpResult Function(String)> okOf = {};
  setUpAll(() {
    all = {
      'google': google,
      'openai_compatible': compat,
      'anthropic': anthropic,
      'openai': openai,
    };
    okOf = {
      'google': googleOk,
      'openai_compatible': chatOk,
      'anthropic': anthropicOk,
      'openai': openaiOk,
    };
  });

  group('google', () {
    test('кадры: подпись t=… перед каждым изображением, системный промпт, '
        'JSON-режим, лимит ответа, ключ — только в заголовке', () async {
      final http = FakeHttp((c, i) => googleOk(_report));
      final r = await analyze(google(http), req(frames));
      final c = http.calls.single;
      expect(c.uri.toString(),
          'https://g.test/v1beta/models/gemini-3.8-flash:generateContent');
      expect(c.uri.toString(), isNot(contains(_key)));
      expect(c.headers['x-goog-api-key'], _key);
      final b = FakeHttp.body(c);
      expect(b['systemInstruction']['parts'][0]['text'], 'SYSTEM');
      final parts = b['contents'][0]['parts'] as List;
      expect(parts[0], {'text': 't=0.00'});
      expect(parts[1]['inlineData']['mimeType'], 'image/jpeg');
      expect(parts[1]['inlineData']['data'], base64Encode([1, 2, 3]));
      expect(parts[2], {'text': 't=12.50'});
      expect(parts.last, {'text': 'USER'});
      expect(b['generationConfig']['responseMimeType'], 'application/json');
      expect(b['generationConfig']['maxOutputTokens'], maxOutputTokens);
      expect(b['generationConfig'].containsKey('responseSchema'), isFalse);
      expect(r.text, _report);
      expect(r.usage!.inputTokens, 1000);
      expect(r.usage!.thinkingTokens, 50);
    });

    test('повтор: прошлый ответ — сообщение model, затем описание ошибок', () async {
      final http = FakeHttp((c, i) => googleOk(_report));
      await analyze(google(http), req(frames, retry: true));
      final contents = FakeHttp.body(http.calls.single)['contents'] as List;
      expect(contents, hasLength(3));
      expect(contents[1], {
        'role': 'model',
        'parts': [
          {'text': 'PREVIOUS'}
        ]
      });
      expect(contents[2]['parts'][0]['text'], 'RETRY NOTE');
    });

    test('видео: небольшое — inline с videoMetadata.fps', () async {
      final http = FakeHttp((c, i) => googleOk(_report));
      await analyze(google(http), req(video, fps: 4));
      final parts = FakeHttp.body(http.calls.single)['contents'][0]['parts'] as List;
      expect(parts.first['inlineData']['mimeType'], 'video/mp4');
      expect(parts.first['videoMetadata'], {'fps': 4.0});
    });

    group('видео через File API', () {
      FakeHttp fileApi({HttpResult? generate, bool hangOnGenerate = false,
          Completer<void>? started}) {
        var polls = 0;
        return FakeHttp((c, i) async {
          final u = c.uri.toString();
          if (u == 'https://g.test/upload/v1beta/files') {
            expect(c.headers['x-goog-upload-command'], 'start');
            expect(c.headers['x-goog-upload-header-content-length'], '30');
            return jsonResult(200, {}, {'x-goog-upload-url': 'https://up.test/1'});
          }
          if (u == 'https://up.test/1') {
            expect(c.bodyFile, isNotNull);
            return jsonResult(200, {
              'file': {
                'name': 'files/abc',
                'uri': 'https://g.test/v1beta/files/abc',
                'state': 'PROCESSING'
              }
            });
          }
          if (c.method == 'GET' && u.endsWith('/files/abc')) {
            polls++;
            return jsonResult(200, {'state': polls < 2 ? 'PROCESSING' : 'ACTIVE'});
          }
          if (c.method == 'DELETE') return jsonResult(200, {});
          if (hangOnGenerate) {
            started?.complete();
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          return generate ?? googleOk(_report);
        });
      }

      test('загрузка → ожидание ACTIVE → ссылка в запросе → удаление файла',
          () async {
        final http = fileApi();
        final progress = <AiProgress>[];
        final r = await analyze(google(http, inlineMax: 10), req(video),
            progress: progress);
        final gen = http.calls.firstWhere((c) => c.uri.path.endsWith(':generateContent'));
        final part = (FakeHttp.body(gen)['contents'][0]['parts'] as List).first;
        expect(part['fileData'],
            {'mimeType': 'video/mp4', 'fileUri': 'https://g.test/v1beta/files/abc'});
        expect(part['videoMetadata'], {'fps': 2.0});
        expect(http.calls.last.method, 'DELETE');
        expect(http.calls.last.uri.toString(), 'https://g.test/v1beta/files/abc');
        expect(progress.map((p) => p.phase), contains(AiPhase.processing));
        expect(r.notes.join(' '), contains('удалён'));
        expect(r.sentBytes, greaterThanOrEqualTo(30));
      });

      test('ошибка ответа — файл всё равно удаляется', () async {
        final http = fileApi(generate: jsonResult(500, {'error': {'message': 'x'}}));
        await expectLater(analyze(google(http, inlineMax: 10), req(video)),
            throwsA(isA<AiException>().having((e) => e.kind, 'kind', AiErrorKind.server)));
        expect(http.calls.last.method, 'DELETE');
      });

      test('отмена во время ожидания ответа — файл удаляется', () async {
        final started = Completer<void>();
        final http = fileApi(hangOnGenerate: true, started: started);
        final cancel = CancelToken();
        final f = analyze(google(http, inlineMax: 10), req(video), cancel: cancel);
        await started.future;
        cancel.cancel();
        await expectLater(f, throwsA(isA<AnalysisCancelled>()));
        expect(http.calls.last.method, 'DELETE');
      });

      test('обработка не удалась (FAILED) — понятная ошибка, файл удалён', () async {
        final http = FakeHttp((c, i) {
          final u = c.uri.toString();
          if (u.endsWith('/upload/v1beta/files')) {
            return jsonResult(200, {}, {'x-goog-upload-url': 'https://up.test/1'});
          }
          if (u == 'https://up.test/1') {
            return jsonResult(200, {'file': {'name': 'files/abc', 'uri': 'u'}});
          }
          if (c.method == 'GET') return jsonResult(200, {'state': 'FAILED'});
          return jsonResult(200, {});
        });
        await expectLater(analyze(google(http, inlineMax: 10), req(video)),
            throwsA(isA<AiException>()));
        expect(http.calls.last.method, 'DELETE');
        expect(http.calls.where((c) => c.uri.path.endsWith(':generateContent')), isEmpty);
      });
    });

    test('блокировка фильтрами → blocked', () async {
      final http = FakeHttp((c, i) => jsonResult(200, {
            'promptFeedback': {'blockReason': 'SAFETY'}
          }));
      await expectLater(analyze(google(http), req(frames)),
          throwsA(isA<AiException>().having((e) => e.kind, 'kind', AiErrorKind.blocked)));
    });

    test('неверный ключ (400 API_KEY_INVALID) → invalidKey', () async {
      final http = FakeHttp((c, i) => jsonResult(400, {
            'error': {
              'code': 400,
              'message': 'API key not valid. Please pass a valid API key.',
              'status': 'INVALID_ARGUMENT'
            }
          }));
      await expectLater(analyze(google(http), req(frames)),
          throwsA(isA<AiException>().having((e) => e.kind, 'kind', AiErrorKind.invalidKey)));
    });

    test('лимит Google (429 с «billing» в тексте) — лимит, а не «нет средств»',
        () async {
      final http = FakeHttp((c, i) => jsonResult(429, {
            'error': {
              'message': 'You exceeded your current quota, please check your '
                  'plan and billing details.',
              'status': 'RESOURCE_EXHAUSTED'
            }
          }));
      await expectLater(analyze(google(http), req(frames)),
          throwsA(isA<AiException>().having((e) => e.kind, 'kind', AiErrorKind.rateLimit)));
    });

    test('модель: найдена / не найдена', () async {
      final ok = FakeHttp((c, i) => jsonResult(200, {'name': 'models/x'}));
      expect((await google(ok).lookupModel(CancelToken()))!.found, isTrue);
      expect(ok.calls.single.uri.path, '/v1beta/models/gemini-3.8-flash');
      final missing = FakeHttp((c, i) => jsonResult(404, {}));
      expect((await google(missing).lookupModel(CancelToken()))!.found, isFalse);
      final offline = FakeHttp((c, i) => throw const AiException(AiErrorKind.network));
      expect(await google(offline).lookupModel(CancelToken()), isNull);
    });
  });

  group('openai_compatible', () {
    test('кадры: system, image_url с data URL, подписи, json_object', () async {
      final http = FakeHttp((c, i) => chatOk(_report));
      final r = await analyze(compat(http), req(frames));
      final c = http.calls.single;
      expect(c.uri.toString(), 'https://or.test/api/v1/chat/completions');
      expect(c.headers['authorization'], 'Bearer $_key');
      final b = FakeHttp.body(c);
      expect(b['model'], 'nvidia/x:free');
      expect(b['messages'][0], {'role': 'system', 'content': 'SYSTEM'});
      final content = b['messages'][1]['content'] as List;
      expect(content[0], {'type': 'text', 'text': 't=0.00'});
      expect(content[1]['image_url']['url'],
          'data:image/jpeg;base64,${base64Encode([1, 2, 3])}');
      expect(content.last, {'type': 'text', 'text': 'USER'});
      expect(b['response_format'], {'type': 'json_object'});
      expect(b['max_tokens'], maxOutputTokens);
      expect(r.usage!.thinkingTokens, 5);
    });

    test('видео — video_url с data URL', () async {
      final http = FakeHttp((c, i) => chatOk(_report));
      await analyze(compat(http), req(video));
      final content = FakeHttp.body(http.calls.single)['messages'][1]['content'] as List;
      expect(content.first['type'], 'video_url');
      expect(content.first['video_url']['url'],
          'data:video/mp4;base64,${base64Encode(List.filled(30, 9))}');
    });

    test('повтор: ответ модели — сообщение assistant', () async {
      final http = FakeHttp((c, i) => chatOk(_report));
      await analyze(compat(http), req(frames, retry: true));
      final m = FakeHttp.body(http.calls.single)['messages'] as List;
      expect(m[2], {'role': 'assistant', 'content': 'PREVIOUS'});
      expect(m[3], {'role': 'user', 'content': 'RETRY NOTE'});
    });

    test('JSON-режим не принят (400) — один повтор без него', () async {
      final http = FakeHttp((c, i) => i == 0
          ? jsonResult(400, {
              'error': {'message': 'response_format is not supported by this model'}
            })
          : chatOk(_report));
      final r = await analyze(compat(http), req(frames));
      expect(http.calls, hasLength(2));
      expect(FakeHttp.body(http.calls[1]).containsKey('response_format'), isFalse);
      expect(r.notes.single, contains('JSON-режим'));
    });

    test('лимит ответа не принят (400) — повтор без max_tokens', () async {
      final http = FakeHttp((c, i) => i == 0
          ? jsonResult(400, {
              'error': {'message': 'max_tokens must be less than or equal to 8192'}
            })
          : chatOk(_report));
      await analyze(compat(http), req(frames));
      expect(FakeHttp.body(http.calls[1]).containsKey('max_tokens'), isFalse);
    });

    test('ошибка в теле ответа 200', () async {
      final http = FakeHttp((c, i) => jsonResult(200, {
            'error': {'code': 429, 'message': 'Rate limit exceeded: free-models-per-day'}
          }));
      await expectLater(
          analyze(compat(http), req(frames)),
          throwsA(isA<AiException>()
              .having((e) => e.kind, 'kind', AiErrorKind.rateLimit)
              .having((e) => e.freeTier, 'freeTier', isTrue)));
    });

    test('429 с Retry-After', () async {
      final http = FakeHttp((c, i) =>
          jsonResult(429, {'error': {'message': 'slow down'}}, {'retry-after': '42'}));
      await expectLater(
          analyze(compat(http, model: 'paid/model'), req(frames)),
          throwsA(isA<AiException>()
              .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 42))
              .having((e) => e.freeTier, 'freeTier', isFalse)));
    });

    test('ответ обёрнут в ```json и текст вокруг — JSON вырезан', () async {
      final http = FakeHttp((c, i) =>
          chatOk('Вот отчёт:\n```json\n$_report\n```\nУдачи!'));
      expect((await analyze(compat(http), req(frames))).text, _report);
    });

    test('возможности модели: input_modalities из /models', () async {
      final http = FakeHttp((c, i) => jsonResult(200, {
            'data': [
              {
                'id': 'nvidia/x:free',
                'architecture': {
                  'input_modalities': ['text', 'image', 'video', 'audio']
                }
              },
              {'id': 'other'},
            ]
          }));
      final m = await compat(http).lookupModel(CancelToken());
      expect(http.calls.single.uri.toString(), 'https://or.test/api/v1/models');
      expect(m!.found, isTrue);
      expect(m.inputModalities, ['text', 'image', 'video', 'audio']);
      final missing = await compat(http, model: 'nope').lookupModel(CancelToken());
      expect(missing!.found, isFalse);
    });
  });

  group('anthropic', () {
    test('кадры: system, image base64, подписи; без prefill и без JSON-режима',
        () async {
      final http = FakeHttp((c, i) => anthropicOk(_report));
      await analyze(anthropic(http), req(frames, retry: true));
      final c = http.calls.single;
      expect(c.uri.toString(), 'https://a.test/v1/messages');
      expect(c.headers['authorization'], 'Bearer $_key');
      expect(c.headers.containsKey('x-api-key'), isFalse);
      expect(c.headers['anthropic-version'], '2026-10-21');
      final b = FakeHttp.body(c);
      expect(b['system'], 'SYSTEM');
      expect(b['max_tokens'], 16000);
      for (final k in ['temperature', 'top_p', 'top_k']) {
        expect(b.containsKey(k), isFalse);
      }
      final m = b['messages'] as List;
      final content = m[0]['content'] as List;
      expect(content[0], {'type': 'text', 'text': 't=0.00'});
      expect(content[1]['source'],
          {'type': 'base64', 'media_type': 'image/jpeg', 'data': base64Encode([1, 2, 3])});
      expect(m[1], {'role': 'assistant', 'content': 'PREVIOUS'});
      // Последнее сообщение — пользователя (prefill запрещён).
      expect(m.last['role'], 'user');
      expect(b.containsKey('output_config'), isFalse);
    });

    test('лимит кадров адаптера — 100', () {
      expect(AdapterRegistry.capabilitiesFor(ApiType.anthropic).frameOptions.maxFrames, 100);
      expect(AdapterRegistry.capabilitiesFor(ApiType.anthropic).supportsVideo, isFalse);
    });

    test('529 overloaded → server; 413 → tooLarge', () async {
      for (final (status, kind) in [
        (529, AiErrorKind.server),
        (413, AiErrorKind.tooLarge),
      ]) {
        final http = FakeHttp((c, i) => jsonResult(status, {
              'type': 'error',
              'error': {'type': 'x', 'message': 'm'}
            }));
        await expectLater(analyze(anthropic(http), req(frames)),
            throwsA(isA<AiException>().having((e) => e.kind, 'kind', kind)));
      }
    });
  });

  group('openai', () {
    test('Responses API: instructions, input_image, json_object, store: false',
        () async {
      final http = FakeHttp((c, i) => openaiOk(_report));
      final r = await analyze(openai(http), req(frames));
      final c = http.calls.single;
      expect(c.uri.toString(), 'https://o.test/v1/responses');
      final b = FakeHttp.body(c);
      expect(b['instructions'], 'SYSTEM');
      final content = b['input'][0]['content'] as List;
      expect(content[0], {'type': 'input_text', 'text': 't=0.00'});
      expect(content[1], {
        'type': 'input_image',
        'image_url': 'data:image/jpeg;base64,${base64Encode([1, 2, 3])}'
      });
      expect(b['text'], {
        'format': {'type': 'json_object'}
      });
      expect(b['max_output_tokens'], maxOutputTokens);
      expect(b['store'], isFalse);
      expect(r.text, _report);
      expect(r.usage!.thinkingTokens, 1);
    });

    test('отказ модели → blocked', () async {
      final http = FakeHttp((c, i) => jsonResult(200, {
            'output': [
              {
                'type': 'message',
                'content': [
                  {'type': 'refusal', 'refusal': 'нет'}
                ]
              }
            ]
          }));
      await expectLater(analyze(openai(http), req(frames)),
          throwsA(isA<AiException>().having((e) => e.kind, 'kind', AiErrorKind.blocked)));
    });
  });

  group('все адаптеры', () {
    final statuses = {
      401: AiErrorKind.invalidKey,
      402: AiErrorKind.insufficientFunds,
      403: AiErrorKind.invalidKey,
      404: AiErrorKind.modelUnavailable,
      413: AiErrorKind.tooLarge,
      429: AiErrorKind.rateLimit,
      500: AiErrorKind.server,
      503: AiErrorKind.server,
    };
    for (final name in ['google', 'openai_compatible', 'anthropic', 'openai']) {
      test('$name: HTTP-ошибки → вид ошибки; ключ не попадает в тексты, даже '
          'если сервер его процитировал', () async {
        for (final MapEntry(key: status, value: kind) in statuses.entries) {
          final http = FakeHttp((c, i) => jsonResult(status, {
                'error': {'message': 'bad key $_key in ?key=$_key'}
              }));
          try {
            await analyze(all[name]!(http), req(frames));
            fail('нет ошибки для $status');
          } on AiException catch (e) {
            expect(e.kind, kind, reason: '$name $status');
            expect(e.toString(), isNot(contains(_key)));
            expect(e.detail, isNot(contains(_key)));
            // И в понятном сообщении пользователю.
            final f = AnalysisFailure.fromAi(e);
            expect([f.title, f.message, ...f.details].join(' '), isNot(contains(_key)));
          }
        }
      });

      test('$name: сеть недоступна → network', () async {
        final http = FakeHttp((c, i) => throw const AiException(AiErrorKind.network, 'SocketException (x)'));
        await expectLater(analyze(all[name]!(http), req(frames)),
            throwsA(isA<AiException>().having((e) => e.kind, 'kind', AiErrorKind.network)));
      });

      test('$name: отмена до ответа → AnalysisCancelled', () async {
        final cancel = CancelToken();
        final http = FakeHttp((c, i) async {
          cancel.cancel();
          return okOf[name]!(_report);
        });
        await expectLater(analyze(all[name]!(http), req(frames), cancel: cancel),
            throwsA(isA<AnalysisCancelled>()));
      });

      test('$name: прогресс — отправка, затем ожидание ответа', () async {
        final http = FakeHttp((c, i) => okOf[name]!(_report));
        final progress = <AiProgress>[];
        await analyze(all[name]!(http), req(frames), progress: progress);
        expect(progress.first.phase, AiPhase.sending);
        expect(progress.map((p) => p.fraction), contains(0.5));
        expect(progress.last.phase, AiPhase.waiting);
      });
    }
  });

  group('общие функции', () {
    test('extractJson', () {
      expect(extractJson('```json\n{"a":1}\n```'), '{"a":1}');
      expect(extractJson('```\n{"a":1}\n```'), '{"a":1}');
      expect(extractJson('Ответ: {"a":{"b":2}} — готово'), '{"a":{"b":2}}');
      expect(extractJson('  {"a":1}  '), '{"a":1}');
      expect(extractJson('нет json'), 'нет json');
    });

    test('redact', () {
      expect(redact('x $_key y', _key), 'x *** y');
      expect(redact('https://h/?key=abc&x=1', null), 'https://h/?key=***&x=1');
    });

    test('Retry-After: секунды и дата', () {
      expect(retryAfter(textResult(429, '', {'retry-after': '7'})),
          const Duration(seconds: 7));
      final at = DateTime.now().toUtc().add(const Duration(minutes: 2));
      final d = retryAfter(textResult(429, '', {'retry-after': HttpDate.format(at)}));
      expect(d!.inSeconds, inInclusiveRange(100, 120));
    });

    test('сообщение «лимит»: через сколько повторить и дневной лимит бесплатных',
        () {
      final f = AnalysisFailure.fromAi(const AiException(
          AiErrorKind.rateLimit, null, Duration(seconds: 90), true));
      expect(f.message, contains('2 мин'));
      expect(f.message, contains('дневной лимит'));
    });

    test('слишком большой запрос в режиме видео → «Отправить кадрами»', () {
      final f = AnalysisFailure.fromAi(const AiException(AiErrorKind.tooLarge),
          videoMode: true);
      expect(f.kind, FailureKind.videoTooLarge);
      expect(f.actions.first, FailureAction.sendFrames);
      expect(AnalysisFailure.fromAi(const AiException(AiErrorKind.tooLarge)).kind,
          FailureKind.tooLarge);
    });

    test('реестр: возможности по типу API', () {
      final g = AdapterRegistry.capabilitiesFor(ApiType.google);
      expect(g.supportsVideo, isTrue);
      expect(g.videoFpsConfigurable, isTrue);
      expect(g.maxVideoBytes, isNull);
      final o = AdapterRegistry.capabilitiesFor(ApiType.openaiCompatible);
      expect(o.supportsVideo, isTrue);
      expect(o.maxVideoBytes, 20 * 1024 * 1024);
      expect(AdapterRegistry.capabilitiesFor(ApiType.openai).supportsVideo, isFalse);
      expect(AdapterRegistry.realAdaptersAvailable, isTrue);
    });
  });

  test('IoHttpTransport: отмена обрывает запрос сразу', () async {
    // Локальный сервер, который не отвечает.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) {/* молчит */});
    final cancel = CancelToken();
    final sw = Stopwatch()..start();
    final f = IoHttpTransport().send(
        HttpCall.json('POST', Uri.parse('http://127.0.0.1:${server.port}/x'), {'a': 1}),
        cancel: cancel);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    cancel.cancel();
    await expectLater(f, throwsA(isA<AnalysisCancelled>()));
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('IoHttpTransport: ответ, статус, заголовки, процент отправки', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      final body = await utf8.decodeStream(r);
      r.response
        ..statusCode = 429
        ..headers.set('Retry-After', '5')
        ..write('{"echo": ${body.length}}');
      await r.response.close();
    });
    final fractions = <double>[];
    final r = await IoHttpTransport().send(
      HttpCall.json('POST', Uri.parse('http://127.0.0.1:${server.port}/x'),
          {'data': 'x' * 200000}),
      cancel: CancelToken(),
      onUpload: fractions.add,
    );
    expect(r.status, 429);
    expect(r.headers['retry-after'], '5');
    expect((r.json as Map)['echo'], greaterThan(200000));
    expect(fractions.length, greaterThan(2));
    expect(fractions.last, 1);
  });

  test('IoHttpTransport: нет сервера → network без подробностей запроса', () async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    await expectLater(
      IoHttpTransport().send(
          HttpCall(method: 'GET', uri: Uri.parse('http://127.0.0.1:$port/x?key=$_key'),
              headers: {'x-api-key': _key}),
          cancel: CancelToken()),
      throwsA(isA<AiException>()
          .having((e) => e.kind, 'kind', AiErrorKind.network)
          .having((e) => e.toString(), 'text', isNot(contains(_key)))),
    );
  });
}
