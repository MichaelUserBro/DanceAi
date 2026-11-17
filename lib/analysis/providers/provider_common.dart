import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../ai_provider.dart';
import '../video_preparer.dart';
import 'http_transport.dart';

/// Лимит ответа для всех адаптеров: подробный отчёт (10–20 ошибок, вердикты
/// по всем критериям, фигуры) плюс «размышление» модели.
const int maxOutputTokens = 32000;

/// Убирает ключ из любого текста (на случай, если сервер его процитировал).
String redact(String text, String? key) {
  var out = text;
  if (key != null && key.length >= 4) out = out.replaceAll(key, '***');
  // Похожее на ключ в query-параметрах.
  return out.replaceAll(RegExp(r'key=[^&\s"]+'), 'key=***');
}

String _short(String s, [int max = 400]) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

/// Ответ модели может быть обёрнут в ```json … ``` или окружён текстом —
/// вырезаем сам объект (это не ошибка). Если объекта нет — как есть.
String extractJson(String raw) {
  var text = raw.trim();
  final fence = RegExp(r'```(?:json|JSON)?\s*\n?([\s\S]*?)```').firstMatch(text);
  if (fence != null) text = fence.group(1)!.trim();
  if (text.startsWith('{') && text.endsWith('}')) return text;
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start >= 0 && end > start) return text.substring(start, end + 1);
  return raw.trim();
}

/// Текст ошибки из тела ответа (форматы разных API).
String errorMessage(HttpResult r) {
  final j = r.json;
  if (j is Map) {
    final e = j['error'];
    if (e is Map) {
      final m = e['message'];
      final meta = e['metadata'];
      final raw = meta is Map ? meta['raw'] : null;
      return [
        if (e['type'] != null) '${e['type']}',
        if (e['status'] != null) '${e['status']}',
        if (e['code'] != null) '${e['code']}',
        if (m != null) '$m',
        if (raw != null) _short('$raw', 200),
      ].join(': ');
    }
    if (e is String) return e;
    if (j['message'] != null) return '${j['message']}';
  }
  return _short(r.text);
}

Duration? retryAfter(HttpResult r) {
  final v = r.headers['retry-after'];
  if (v == null) return null;
  final s = int.tryParse(v.trim());
  if (s != null) return Duration(seconds: s);
  final d = double.tryParse(v.trim());
  if (d != null) return Duration(milliseconds: (d * 1000).round());
  try {
    final at = HttpDate.parse(v);
    final diff = at.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  } catch (_) {
    return null;
  }
}

/// HTTP-ошибка → [AiErrorKind] (spec 7.7 п. 4). Общая для всех API: коды
/// и тексты стандартные; особые случаи адаптер проверяет сам до вызова.
AiException httpError(HttpResult r, {required String? key, bool freeTier = false}) {
  final msg = errorMessage(r);
  final lower = msg.toLowerCase();
  final detail = redact('HTTP ${r.status}: ${_short(msg)}', key);
  bool has(List<String> words) => words.any(lower.contains);

  final AiErrorKind kind;
  if (r.status == 401 ||
      has(['api_key_invalid', 'api key not valid', 'invalid api key',
          'incorrect api key', 'invalid x-api-key', 'authentication'])) {
    kind = AiErrorKind.invalidKey;
  } else if (r.status == 402 ||
      has(['insufficient_quota', 'credit_balance', 'insufficient credits',
          'billing_error', 'spend_limit', 'spend limit', 'credit balance'])) {
    kind = AiErrorKind.insufficientFunds;
  } else if (r.status == 413 ||
      has(['too large', 'too_large', 'payload_too_large', 'request size',
          'exceeds the maximum', 'request_too_large'])) {
    kind = AiErrorKind.tooLarge;
  } else if (r.status == 429) {
    kind = AiErrorKind.rateLimit;
  } else if ((r.status == 403 || r.status == 400 || r.status == 422) &&
      has(['moderation', 'flagged', 'content_policy', 'guardrail', 'safety'])) {
    // Например, Nvidia через OpenRouter: 422 «input rejected by content
    // safety screening» (в т. ч. при большом числе изображений).
    kind = AiErrorKind.blocked;
  } else if (r.status == 403) {
    kind = AiErrorKind.invalidKey;
  } else if (r.status == 404 ||
      has(['model_not_found', 'model not found', 'no endpoints found',
          'is not found', 'does not exist', 'not supported for',
          'does not support image', 'does not support video',
          'image input', 'video input', 'modalit', 'unsupported mime',
          'invalid model'])) {
    kind = AiErrorKind.modelUnavailable;
  } else {
    kind = AiErrorKind.server;
  }
  return AiException(
    kind,
    detail,
    kind == AiErrorKind.rateLimit ? retryAfter(r) : null,
    kind == AiErrorKind.rateLimit && freeTier,
  );
}

/// Ошибка 400 из-за JSON-режима: модель/сервер его не поддерживает.
bool isJsonModeRejected(HttpResult r) {
  if (r.status != 400 && r.status != 422) return false;
  final m = errorMessage(r).toLowerCase();
  return m.contains('response_format') ||
      m.contains('json_object') ||
      m.contains('json mode') ||
      m.contains('responsemimetype') ||
      m.contains('response_mime_type') ||
      m.contains('text.format');
}

/// Кадры и их подписи: `t=12.50` перед каждым изображением (input_frames.md).
Future<List<(String label, String base64, String mime)>> loadFrames(
    PreparedMaterial m) async {
  final out = <(String, String, String)>[];
  for (final f in m.frames) {
    final bytes = await File(f.path).readAsBytes();
    out.add((f.label, base64Encode(bytes), mimeOf(f.path)));
  }
  return out;
}

String mimeOf(String path) {
  final p = path.toLowerCase();
  if (p.endsWith('.png')) return 'image/png';
  if (p.endsWith('.webp')) return 'image/webp';
  if (p.endsWith('.mp4')) return 'video/mp4';
  if (p.endsWith('.mov')) return 'video/mov';
  return 'image/jpeg';
}

/// Видео целиком (облегчённая копия) в base64.
Future<String> videoBase64(PreparedMaterial m) async {
  final path = m.video?.path;
  if (path == null) {
    throw const AiException(AiErrorKind.server, 'нет облегчённой копии видео');
  }
  final Uint8List bytes = await File(path).readAsBytes();
  return base64Encode(bytes);
}

/// Пользовательский текст запроса, а при повторе — с описанием ошибок.
String retryText(AiRequest r) => r.retryNote ?? '';

int? asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
