import 'dart:convert';
import 'dart:typed_data';

import '../ai_provider.dart';
import '../cancel_token.dart';
import 'http_transport.dart';
import 'provider_common.dart';

/// Параметры запроса, которые адаптер может ослабить при повторе:
/// JSON-режим и лимит ответа (не все модели/серверы их принимают).
class CallOptions {
  const CallOptions({this.jsonMode = true, this.limitTokens = true});
  final bool jsonMode;
  final bool limitTokens;
}

/// Общая часть адаптеров на HTTP: отправка с прогрессом, один повтор без
/// JSON-режима (или без лимита токенов), если сервер их не принял (400),
/// разбор ошибок. Логика конкретного API — в наследниках.
abstract class HttpAiProvider implements AiProvider {
  HttpAiProvider({
    required this.model,
    required String apiKey,
    required String baseUrl,
    required this.transport,
    required this.displayName,
  })  : key = apiKey,
        baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl;

  @override
  final String model;

  /// Ключ: только в заголовке запроса, никогда в текстах.
  final String key;
  final String baseUrl;
  final HttpTransport transport;

  @override
  final String displayName;

  /// API допускает запрос без лимита ответа (у части API он обязателен).
  bool get canDropTokenLimit => true;

  /// Бесплатная модель с дневным лимитом (подсказка в ошибке 429).
  bool get freeTier => false;

  /// Подготовка материала до запроса (например, загрузка файла).
  /// Возвращённое значение попадёт в [buildCall] и [cleanup].
  Future<Object?> prepareMedia(AiRequest request,
          void Function(AiProgress) onProgress, CancelToken cancel,
          List<String> notes) async =>
      null;

  /// Освобождение того, что сделал [prepareMedia] (в любом исходе).
  Future<void> cleanup(Object? media, List<String> notes) async {}

  Future<HttpCall> buildCall(AiRequest request, Object? media, CallOptions o);

  /// Текст ответа и сведения. Ошибку в теле ответа 200 — бросить.
  AiResponse parse(HttpResult r, {required int sentBytes, required List<String> notes});

  /// Сколько байт материала ушло отдельно (загруженный файл).
  int uploadedBytes(Object? media) => 0;

  @override
  Future<AiResponse> analyze(
    AiRequest request, {
    required void Function(AiProgress) onProgress,
    required CancelToken cancel,
  }) async {
    final notes = <String>[];
    Object? media;
    try {
      onProgress(const AiProgress(AiPhase.sending, 0));
      media = await prepareMedia(request, onProgress, cancel, notes);
      var options = const CallOptions();
      for (var attempt = 0; attempt < 3; attempt++) {
        cancel.throwIfCancelled();
        final call = await buildCall(request, media, options);
        onProgress(const AiProgress(AiPhase.sending, 0));
        final r = await transport.send(
          call,
          cancel: cancel,
          onUpload: (f) => onProgress(f < 1
              ? AiProgress(AiPhase.sending, f)
              : const AiProgress(AiPhase.waiting)),
        );
        cancel.throwIfCancelled();
        if (!r.ok) {
          if (options.jsonMode && isJsonModeRejected(r)) {
            notes.add('JSON-режим не принят (HTTP ${r.status}) — повтор без него');
            options = CallOptions(jsonMode: false, limitTokens: options.limitTokens);
            continue;
          }
          if (options.limitTokens && canDropTokenLimit && _isTokenLimitRejected(r)) {
            notes.add('лимит ответа не принят (HTTP ${r.status}) — повтор без него');
            options = CallOptions(jsonMode: options.jsonMode, limitTokens: false);
            continue;
          }
          throw httpError(r, key: key, freeTier: freeTier);
        }
        return parse(r,
            sentBytes: call.body.length + uploadedBytes(media), notes: notes);
      }
      throw const AiException(AiErrorKind.server, 'запрос не принят');
    } on AiException catch (e) {
      // Последняя страховка: ключ не должен попасть в подробности.
      final d = e.detail;
      if (d != null && redact(d, key) != d) {
        throw AiException(e.kind, redact(d, key), e.retryAfter, e.freeTier);
      }
      rethrow;
    } finally {
      await cleanup(media, notes);
    }
  }

  bool _isTokenLimitRejected(HttpResult r) {
    if (r.status != 400 && r.status != 422) return false;
    final m = errorMessage(r).toLowerCase();
    return m.contains('max_tokens') ||
        m.contains('max_output_tokens') ||
        m.contains('maxoutputtokens') ||
        m.contains('max_completion_tokens');
  }

  /// Ошибка внутри ответа 200 (так бывает у OpenAI-совместимых сервисов).
  static AiException? errorInBody(Map body, String key, {bool freeTier = false}) {
    final e = body['error'];
    if (e == null) return null;
    final code = e is Map ? asInt(e['code']) : null;
    return httpError(
      HttpResult(code ?? 502, const {}, Uint8List.fromList(utf8.encode(jsonEncode(body)))),
      key: key,
      freeTier: freeTier,
    );
  }

  /// Ответ без ожидаемой структуры.
  AiException malformed(HttpResult r) => AiException(
      AiErrorKind.server, redact('неожиданный ответ: ${errorMessage(r)}', key));

  Map<String, dynamic> bodyOf(HttpResult r) {
    final j = r.json;
    if (j is Map<String, dynamic>) return j;
    throw malformed(r);
  }
}
