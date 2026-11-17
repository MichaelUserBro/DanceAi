import '../ai_provider.dart';
import '../cancel_token.dart';
import '../video_preparer.dart';
import 'http_ai_provider.dart';
import 'http_transport.dart';
import 'provider_common.dart';

/// Адаптер OpenAI-совместимого API (`api_type: openai_compatible`):
/// OpenRouter и «Свой». `POST {base}/chat/completions`.
///
/// Особенности (openrouter.ai/docs, ноябрь 2026):
/// - изображения — `image_url` (data URL), видео — `video_url` (data URL
///   `data:video/mp4;base64,…`); лимит размера видео не документирован —
///   свой порог 20 МБ облегчённой копии, 413 → «Отправить кадрами»;
/// - `response_format: {type: json_object}`; параметры, которые модель не
///   поддерживает, OpenRouter молча игнорирует; другие серверы могут
///   ответить 400 — тогда повтор без JSON-режима;
/// - ошибка может прийти в теле ответа 200 (`error`);
/// - бесплатные модели (`:free`) — 20 запросов/мин и 50/день.
class OpenAiCompatibleProvider extends HttpAiProvider {
  OpenAiCompatibleProvider({
    required super.model,
    required super.apiKey,
    required super.baseUrl,
    required super.transport,
    super.displayName = 'ИИ',
  });

  static const maxVideoBytes = 20 * 1024 * 1024;

  static const capabilitiesStatic = AiCapabilities(
    supportsVideo: true,
    maxVideoBytes: maxVideoBytes,
  );

  @override
  AiCapabilities get capabilities => capabilitiesStatic;

  @override
  bool get freeTier => model.endsWith(':free');

  Map<String, String> get _auth => {'authorization': 'Bearer $key'};

  @override
  Future<HttpCall> buildCall(AiRequest request, Object? media, CallOptions o) async {
    final m = request.material;
    final content = <Map<String, dynamic>>[];
    if (request.mode == SubmissionMode.video) {
      content.add({
        'type': 'video_url',
        'video_url': {'url': 'data:video/mp4;base64,${await videoBase64(m)}'},
      });
    } else {
      for (final (label, b64, mime) in await loadFrames(m)) {
        content
          ..add({'type': 'text', 'text': label})
          ..add({
            'type': 'image_url',
            'image_url': {'url': 'data:$mime;base64,$b64'},
          });
      }
    }
    content.add({'type': 'text', 'text': request.userPrompt});

    return HttpCall.json(
      'POST',
      Uri.parse('$baseUrl/chat/completions'),
      {
        'model': model,
        'messages': [
          {'role': 'system', 'content': request.systemPrompt},
          {'role': 'user', 'content': content},
          if (request.isRetry) ...[
            {'role': 'assistant', 'content': request.previousResponse ?? ''},
            {'role': 'user', 'content': request.retryNote},
          ],
        ],
        if (o.limitTokens) 'max_tokens': maxOutputTokens,
        if (o.jsonMode) 'response_format': {'type': 'json_object'},
      },
      headers: _auth,
    );
  }

  @override
  AiResponse parse(HttpResult r,
      {required int sentBytes, required List<String> notes}) {
    final body = bodyOf(r);
    final err = HttpAiProvider.errorInBody(body, key, freeTier: freeTier);
    final choices = body['choices'];
    if (err != null && (choices is! List || choices.isEmpty)) throw err;
    if (choices is! List || choices.isEmpty) throw malformed(r);
    final c = choices.first as Map;
    final finish = c['finish_reason'] as String?;
    if (finish == 'error' && err != null) throw err;
    final message = c['message'];
    final raw = message is Map ? message['content'] : null;
    final text = switch (raw) {
      String s => s,
      List parts => parts
          .whereType<Map>()
          .where((p) => p['type'] == 'text' && p['text'] is String)
          .map((p) => p['text'] as String)
          .join(),
      _ => '',
    };
    if (text.isEmpty && message is Map && message['refusal'] is String) {
      throw AiException(AiErrorKind.blocked, 'refusal: ${message['refusal']}');
    }
    if (text.isEmpty && finish == 'content_filter') {
      throw const AiException(AiErrorKind.blocked, 'finish_reason: content_filter');
    }
    final u = body['usage'];
    final details = u is Map ? u['completion_tokens_details'] : null;
    return AiResponse(
      text: extractJson(text),
      finishReason: finish,
      sentBytes: sentBytes,
      notes: notes,
      usage: u is Map
          ? AiUsage(
              inputTokens: asInt(u['prompt_tokens']),
              outputTokens: asInt(u['completion_tokens']),
              thinkingTokens:
                  details is Map ? asInt(details['reasoning_tokens']) : null,
            )
          : null,
    );
  }

  /// `GET {base}/models`: у OpenRouter — `architecture.input_modalities`;
  /// у других серверов — только список id (тогда модальности неизвестны).
  @override
  Future<ModelLookup?> lookupModel(CancelToken cancel) async {
    if (model.trim().isEmpty || baseUrl.isEmpty) return null;
    try {
      final r = await transport.send(
        HttpCall(
          method: 'GET',
          uri: Uri.parse('$baseUrl/models'),
          headers: _auth,
          responseTimeout: const Duration(seconds: 20),
        ),
        cancel: cancel,
      );
      if (!r.ok) return null;
      final j = r.json;
      final data = j is Map ? j['data'] : null;
      if (data is! List || data.isEmpty) return null;
      for (final m in data) {
        if (m is Map && m['id'] == model) {
          final arch = m['architecture'];
          final mods = arch is Map ? arch['input_modalities'] : null;
          return ModelLookup(
            found: true,
            inputModalities: mods is List ? mods.cast<String>() : null,
          );
        }
      }
      return const ModelLookup(found: false);
    } on AiException {
      return null;
    }
  }
}
