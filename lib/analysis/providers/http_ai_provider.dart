import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ai_provider.dart';
import '../cancel_token.dart';
import 'http_transport.dart';
import 'provider_common.dart';

/// Параметры запроса, которые адаптер может ослабить при повторе:
/// JSON-режим и лимит ответа (не все модели/серверы их принимают).
class CallOptions {
  const CallOptions(
      {this.jsonMode = true,
      this.limitTokens = true,
      this.useSchema = true,
      this.useThinking = true});
  final bool jsonMode;
  final bool limitTokens;

  /// Строгая схема ответа (где адаптер её передаёт).
  final bool useSchema;

  /// Уровень «размышления» (если задан в запросе и адаптер его передаёт).
  final bool useThinking;

  CallOptions copyWith(
          {bool? jsonMode, bool? limitTokens, bool? useSchema, bool? useThinking}) =>
      CallOptions(
        jsonMode: jsonMode ?? this.jsonMode,
        limitTokens: limitTokens ?? this.limitTokens,
        useSchema: useSchema ?? this.useSchema,
        useThinking: useThinking ?? this.useThinking,
      );
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

  /// Адаптер передаёт строгую схему ответа ([CallOptions.useSchema]).
  bool get usesSchema => false;

  /// Параметры, которые модель отклонила (строгая схема, уровень
  /// размышления), — по каждой модели, до конца сеанса приложения, чтобы не
  /// тратить лишний запрос на каждый анализ.
  static final _rejected = <String>{};

  String _memoryKey(String param) => '$param|$runtimeType|$baseUrl|$model';

  /// Схема для этой модели уже отклонялась в этом сеансе.
  bool get schemaRejectedThisSession => _rejected.contains(_memoryKey('schema'));

  /// Уровень размышления для этой модели уже отклонялся в этом сеансе.
  bool get thinkingRejectedThisSession =>
      _rejected.contains(_memoryKey('thinking'));

  @visibleForTesting
  static void resetSchemaMemory() => _rejected.clear();

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

  /// HTTP-ошибка → [AiException]. Адаптер уточняет по формату своего API
  /// (например, вид исчерпанной квоты у 429).
  AiException classifyError(HttpResult r) =>
      httpError(r, key: key, freeTier: freeTier);

  @override
  Future<AiResponse> analyze(
    AiRequest request, {
    required void Function(AiProgress) onProgress,
    required CancelToken cancel,
  }) async {
    final notes = <String>[];
    Object? media;
    var cleaned = false;
    int? sentBytes;
    HttpDiag? diag;
    var uploaded = 0;
    try {
      onProgress(const AiProgress(AiPhase.sending, 0));
      media = await prepareMedia(request, onProgress, cancel, notes);
      uploaded = uploadedBytes(media);
      var options = const CallOptions();
      if (usesSchema && schemaRejectedThisSession) {
        notes.add('строгая схема не отправлялась: модель отклонила её ранее '
            'в этом сеансе');
        options = options.copyWith(useSchema: false);
      }
      final thinking = request.thinkingLevel != null;
      if (thinking && thinkingRejectedThisSession) {
        notes.add('уровень размышления не отправлялся: модель отклонила его '
            'ранее в этом сеансе');
        options = options.copyWith(useThinking: false);
      }
      for (var attempt = 0; attempt < 5; attempt++) {
        cancel.throwIfCancelled();
        final call = await buildCall(request, media, options);
        final length = call.body.length;
        // Пока ничего не ушло — только загруженный файл (если был).
        sentBytes = uploaded;
        diag = null;
        onProgress(AiProgress(AiPhase.sending, 0, null, uploaded));
        final HttpResult r;
        try {
          r = await transport.send(
            call,
            cancel: cancel,
            onUpload: (f) {
              final bytes = uploaded + (f * length).round();
              onProgress(f < 1
                  ? AiProgress(AiPhase.sending, f, null, bytes)
                  : AiProgress(AiPhase.waiting, null, null, bytes));
            },
            onReceive: (n) => onProgress(AiProgress(AiPhase.waiting, null, n)),
          );
        } on AiException catch (e) {
          // Фактически отправленное транспортом (0 — запрос не ушёл).
          sentBytes = uploaded + (e.sentBytes ?? 0);
          rethrow;
        }
        sentBytes = uploaded + (r.sentBytes ?? length);
        cancel.throwIfCancelled();
        diag = HttpDiag(
            status: r.status,
            headersTime: r.headersTime,
            firstByteTime: r.firstByteTime);
        if (!r.ok) {
          diag = diag.withSource(AiErrorSource.http);
          if (options.useThinking && thinking && isThinkingRejected(r)) {
            notes.add(redact(
                'уровень размышления не принят (${errorMessage(r)}) — повтор '
                'без него',
                key));
            options = options.copyWith(useThinking: false);
            _rejected.add(_memoryKey('thinking'));
            continue;
          }
          if (options.useSchema && usesSchema && isSchemaRejected(r)) {
            notes.add(redact(
                'схема ответа не принята (${errorMessage(r)}) — повтор без неё',
                key));
            options = options.copyWith(useSchema: false);
            _rejected.add(_memoryKey('schema'));
            continue;
          }
          if (options.jsonMode && isJsonModeRejected(r)) {
            notes.add('JSON-режим не принят (HTTP ${r.status}) — повтор без него');
            options = options.copyWith(jsonMode: false);
            continue;
          }
          if (options.limitTokens && canDropTokenLimit && _isTokenLimitRejected(r)) {
            notes.add('лимит ответа не принят (HTTP ${r.status}) — повтор без него');
            options = options.copyWith(limitTokens: false);
            continue;
          }
          throw classifyError(r);
        }
        final AiResponse parsed;
        try {
          parsed = parse(r, sentBytes: sentBytes, notes: notes);
        } on AiException {
          // Ошибка пришла в теле ответа 200 (событие потока SSE и т. п.).
          diag = diag.withSource(AiErrorSource.sse);
          rethrow;
        }
        return AiResponse(
          text: parsed.text,
          usage: parsed.usage,
          finishReason: parsed.finishReason,
          sentBytes: parsed.sentBytes,
          notes: parsed.notes,
          diag: diag,
        );
      }
      throw const AiException(AiErrorKind.server, 'запрос не принят');
    } on AiException catch (e) {
      // Очистка до ошибки — чтобы её заметки (удаление файла) попали в неё.
      cleaned = true;
      await cleanup(media, notes);
      // Последняя страховка: ключ не должен попасть в подробности и заметки.
      final d = e.detail;
      final full = e.fullDetail;
      throw AiException.full(
        e.kind,
        detail: d == null ? null : redact(d, key),
        retryAfter: e.retryAfter,
        freeTier: e.freeTier,
        notes: [for (final n in [...e.notes, ...notes]) redact(n, key)],
        sentBytes: sentBytes ?? e.sentBytes,
        diag: diag ?? e.diag,
        quota: e.quota,
        quotaId: e.quotaId,
        fullDetail: full == null ? null : redact(full, key),
      );
    } finally {
      if (!cleaned) await cleanup(media, notes);
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
