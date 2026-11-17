import '../ai_provider.dart';
import '../cancel_token.dart';
import '../video_preparer.dart';
import 'http_ai_provider.dart';
import 'http_transport.dart';
import 'provider_common.dart';

/// Адаптер OpenAI (`api_type: openai`), Responses API `POST {base}/responses`
/// (документация рекомендует его для новых проектов).
///
/// Особенности (developers.openai.com, ноябрь 2026):
/// - изображения — `input_image` с data URL; видео API не принимает;
/// - системный промпт — `instructions`;
/// - JSON-режим — `text.format: {type: json_object}`;
/// - `max_output_tokens` включает токены «размышления».
class OpenAiProvider extends HttpAiProvider {
  OpenAiProvider({
    required super.model,
    required super.apiKey,
    required super.baseUrl,
    required super.transport,
    super.displayName = 'OpenAI',
  });

  static const capabilitiesStatic = AiCapabilities(supportsVideo: false);

  @override
  AiCapabilities get capabilities => capabilitiesStatic;

  Map<String, String> get _auth => {'authorization': 'Bearer $key'};

  @override
  Future<HttpCall> buildCall(AiRequest request, Object? media, CallOptions o) async {
    if (request.mode == SubmissionMode.video) {
      throw const AiException(AiErrorKind.modelUnavailable, 'видео не поддерживается');
    }
    final content = <Map<String, dynamic>>[];
    for (final (label, b64, mime) in await loadFrames(request.material)) {
      content
        ..add({'type': 'input_text', 'text': label})
        ..add({'type': 'input_image', 'image_url': 'data:$mime;base64,$b64'});
    }
    content.add({'type': 'input_text', 'text': request.userPrompt});
    return HttpCall.json(
      'POST',
      Uri.parse('$baseUrl/responses'),
      {
        'model': model,
        'instructions': request.systemPrompt,
        'input': [
          {'role': 'user', 'content': content},
          if (request.isRetry) ...[
            {'role': 'assistant', 'content': request.previousResponse ?? ''},
            {'role': 'user', 'content': request.retryNote},
          ],
        ],
        if (o.limitTokens) 'max_output_tokens': maxOutputTokens,
        if (o.jsonMode)
          'text': {
            'format': {'type': 'json_object'}
          },
        // Ответ не хранится на стороне OpenAI.
        'store': false,
      },
      headers: _auth,
    );
  }

  @override
  AiResponse parse(HttpResult r,
      {required int sentBytes, required List<String> notes}) {
    final body = bodyOf(r);
    final err = HttpAiProvider.errorInBody(body, key);
    final output = body['output'];
    if (err != null && output is! List) throw err;
    if (output is! List) throw malformed(r);
    final text = StringBuffer();
    String? refusal;
    for (final item in output.whereType<Map>()) {
      if (item['type'] != 'message' || item['content'] is! List) continue;
      for (final c in (item['content'] as List).whereType<Map>()) {
        if (c['type'] == 'output_text' && c['text'] is String) text.write(c['text']);
        if (c['type'] == 'refusal') refusal = '${c['refusal']}';
      }
    }
    if (text.isEmpty && refusal != null) {
      throw AiException(AiErrorKind.blocked, 'refusal: $refusal');
    }
    final incomplete = body['incomplete_details'];
    final finish = body['status'] == 'incomplete' && incomplete is Map
        ? '${incomplete['reason']}'
        : body['status'] as String?;
    final u = body['usage'];
    final details = u is Map ? u['output_tokens_details'] : null;
    return AiResponse(
      text: extractJson(text.toString()),
      finishReason: finish,
      sentBytes: sentBytes,
      notes: notes,
      usage: u is Map
          ? AiUsage(
              inputTokens: asInt(u['input_tokens']),
              outputTokens: asInt(u['output_tokens']),
              thinkingTokens:
                  details is Map ? asInt(details['reasoning_tokens']) : null,
            )
          : null,
    );
  }

  /// `GET /models/{id}`: только есть ли модель (модальности API не сообщает).
  @override
  Future<ModelLookup?> lookupModel(CancelToken cancel) async {
    if (model.trim().isEmpty) return null;
    try {
      final r = await transport.send(
        HttpCall(
          method: 'GET',
          uri: Uri.parse('$baseUrl/models/${Uri.encodeComponent(model)}'),
          headers: _auth,
          responseTimeout: const Duration(seconds: 20),
        ),
        cancel: cancel,
      );
      if (r.ok) return const ModelLookup(found: true);
      if (r.status == 404) return const ModelLookup(found: false);
      return null;
    } on AiException {
      return null;
    }
  }
}
