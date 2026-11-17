import '../ai_provider.dart';
import '../cancel_token.dart';
import '../video_preparer.dart';
import 'http_ai_provider.dart';
import 'http_transport.dart';
import 'provider_common.dart';

/// Адаптер Anthropic (`api_type: anthropic`), `POST {base}/v1/messages`.
///
/// Особенности (platform.claude.com/docs, ноябрь 2026):
/// - только изображения (видео и звук API не принимает);
/// - до 600 изображений за запрос, но 100 — у моделей с окном 200k;
///   больше 20 изображений — каждое не больше 3000 px (у нас 768);
/// - JSON-режима без схемы нет, предзаполнение ответа `{` на новых моделях
///   запрещено (400) — только промпт и вырезание JSON из ответа;
/// - ключ — `x-api-key`, версия — `anthropic-version`.
class AnthropicProvider extends HttpAiProvider {
  AnthropicProvider({
    required super.model,
    required super.apiKey,
    required super.baseUrl,
    required super.transport,
    super.displayName = 'Anthropic',
  });

  static const apiVersion = '2026-10-21';

  static const capabilitiesStatic = AiCapabilities(
    supportsVideo: false,
    frameOptions: FrameOptions(maxFrames: 100),
  );

  @override
  AiCapabilities get capabilities => capabilitiesStatic;

  @override
  bool get canDropTokenLimit => false;

  Map<String, String> get _auth =>
      {'x-api-key': key, 'anthropic-version': apiVersion};

  @override
  Future<HttpCall> buildCall(AiRequest request, Object? media, CallOptions o) async {
    if (request.mode == SubmissionMode.video) {
      throw const AiException(AiErrorKind.modelUnavailable, 'видео не поддерживается');
    }
    final content = <Map<String, dynamic>>[];
    for (final (label, b64, mime) in await loadFrames(request.material)) {
      content
        ..add({'type': 'text', 'text': label})
        ..add({
          'type': 'image',
          'source': {'type': 'base64', 'media_type': mime, 'data': b64},
        });
    }
    content.add({'type': 'text', 'text': request.userPrompt});
    return HttpCall.json(
      'POST',
      Uri.parse('$baseUrl/v1/messages'),
      {
        'model': model,
        // Лимит обязателен в этом API — без него не повторяем.
        'max_tokens': maxOutputTokens,
        'system': request.systemPrompt,
        'messages': [
          {'role': 'user', 'content': content},
          if (request.isRetry) ...[
            {'role': 'assistant', 'content': request.previousResponse ?? ''},
            {'role': 'user', 'content': request.retryNote},
          ],
        ],
      },
      headers: _auth,
    );
  }

  @override
  AiResponse parse(HttpResult r,
      {required int sentBytes, required List<String> notes}) {
    final body = bodyOf(r);
    final blocks = body['content'];
    if (blocks is! List) throw malformed(r);
    final text = blocks
        .whereType<Map>()
        .where((b) => b['type'] == 'text' && b['text'] is String)
        .map((b) => b['text'] as String)
        .join();
    final stop = body['stop_reason'] as String?;
    if (text.isEmpty && stop == 'refusal') {
      throw const AiException(AiErrorKind.blocked, 'stop_reason: refusal');
    }
    final u = body['usage'];
    return AiResponse(
      text: extractJson(text),
      finishReason: stop,
      sentBytes: sentBytes,
      notes: notes,
      usage: u is Map
          ? AiUsage(
              inputTokens: asInt(u['input_tokens']),
              outputTokens: asInt(u['output_tokens']),
            )
          : null,
    );
  }

  /// `GET /v1/models/{id}`: есть ли модель и принимает ли изображения.
  @override
  Future<ModelLookup?> lookupModel(CancelToken cancel) async {
    if (model.trim().isEmpty) return null;
    try {
      final r = await transport.send(
        HttpCall(
          method: 'GET',
          uri: Uri.parse('$baseUrl/v1/models/${Uri.encodeComponent(model)}'),
          headers: _auth,
          responseTimeout: const Duration(seconds: 20),
        ),
        cancel: cancel,
      );
      if (r.status == 404) return const ModelLookup(found: false);
      if (!r.ok) return null;
      final caps = (r.json as Map?)?['capabilities'];
      final image = caps is Map ? caps['image_input'] : null;
      final supported = image is Map ? image['supported'] : null;
      return ModelLookup(
        found: true,
        inputModalities: supported is bool
            ? ['text', if (supported) 'image']
            : null,
      );
    } on AiException {
      return null;
    }
  }
}
