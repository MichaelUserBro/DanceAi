import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../ai_provider.dart';
import '../cancel_token.dart';

/// HTTP-запрос адаптера. Заголовки (в т. ч. ключ) никогда не попадают
/// в тексты ошибок.
class HttpCall {
  HttpCall({
    required this.method,
    required this.uri,
    this.headers = const {},
    Uint8List? body,
    this.bodyFile,
    this.responseTimeout = const Duration(minutes: 10),
  }) : body = body ?? Uint8List(0);

  factory HttpCall.json(
    String method,
    Uri uri,
    Object? json, {
    Map<String, String> headers = const {},
    Duration responseTimeout = const Duration(minutes: 10),
  }) =>
      HttpCall(
        method: method,
        uri: uri,
        headers: {'content-type': 'application/json', ...headers},
        body: json == null ? null : utf8.encode(jsonEncode(json)),
        responseTimeout: responseTimeout,
      );

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Uint8List body;

  /// Тело из файла (загрузка видео) — читается потоком, не целиком в память.
  final String? bodyFile;

  /// Сколько ждать ответа после отправки (модели с «размышлением» отвечают
  /// минутами, но не бесконечно).
  final Duration responseTimeout;
}

class HttpResult {
  const HttpResult(this.status, this.headers, this.body);

  final int status;

  /// Имена — в нижнем регистре.
  final Map<String, String> headers;
  final Uint8List body;

  String get text => utf8.decode(body, allowMalformed: true);

  Object? get json {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  bool get ok => status >= 200 && status < 300;
}

/// Транспорт: в приложении — [IoHttpTransport], в тестах — подделка.
abstract interface class HttpTransport {
  /// Бросает [AiException] (network) при сбое сети или таймауте и
  /// [AnalysisCancelled] при отмене. HTTP-ошибки — обычный [HttpResult].
  Future<HttpResult> send(
    HttpCall call, {
    required CancelToken cancel,
    void Function(double fraction)? onUpload,
    void Function(int receivedBytes)? onReceive,
  });
}

/// [HttpTransport] на dart:io: отмена обрывает соединение сразу.
class IoHttpTransport implements HttpTransport {
  IoHttpTransport({
    this.connectTimeout = const Duration(seconds: 30),
    this.uploadStallTimeout = const Duration(seconds: 60),
  });

  final Duration connectTimeout;

  /// Загрузка не продвигается столько времени — обрыв.
  final Duration uploadStallTimeout;

  static const _chunk = 64 * 1024;

  @override
  Future<HttpResult> send(
    HttpCall call, {
    required CancelToken cancel,
    void Function(double fraction)? onUpload,
    void Function(int receivedBytes)? onReceive,
  }) async {
    cancel.throwIfCancelled();
    final client = HttpClient()
      ..connectionTimeout = connectTimeout
      ..idleTimeout = const Duration(seconds: 15);
    HttpClientRequest? request;
    final cancelSub = cancel.whenCancelled.then((_) {
      request?.abort(const AnalysisCancelled());
      client.close(force: true);
    });
    try {
      request = await client.openUrl(call.method, call.uri);
      cancel.throwIfCancelled();
      request.followRedirects = true;
      call.headers.forEach(request.headers.set);
      final length = call.bodyFile != null
          ? await File(call.bodyFile!).length()
          : call.body.length;
      request.contentLength = length;

      // Тело частями: доля отправленного — для прогресса «Отправка».
      var sent = 0;
      Future<void> write(List<int> data) async {
        for (var i = 0; i < data.length; i += _chunk) {
          cancel.throwIfCancelled();
          final end = i + _chunk < data.length ? i + _chunk : data.length;
          request!.add(data.sublist(i, end));
          await request.flush().timeout(uploadStallTimeout);
          sent += end - i;
          if (length > 0) onUpload?.call(sent / length);
        }
      }

      if (call.bodyFile != null) {
        await for (final part in File(call.bodyFile!).openRead()) {
          await write(part);
        }
      } else if (call.body.isNotEmpty) {
        await write(call.body);
      }
      onUpload?.call(1);

      final response = await request.close().timeout(call.responseTimeout);
      // Тело читается по мере прихода: при потоковой отдаче — живой
      // прогресс «получено N байт».
      final bytes = await response.fold<BytesBuilder>(
          BytesBuilder(copy: false), (b, d) {
        b.add(d);
        onReceive?.call(b.length);
        return b;
      }).timeout(call.responseTimeout);
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(', ');
      });
      return HttpResult(response.statusCode, headers, bytes.takeBytes());
    } on AnalysisCancelled {
      rethrow;
    } catch (e) {
      if (cancel.isCancelled) throw const AnalysisCancelled();
      // Тип и текст ошибки, хост — без заголовков и параметров запроса
      // (ключ передаётся только в заголовке; query на всякий случай режем).
      throw AiException(AiErrorKind.network, _describe(e, call.uri));
    } finally {
      unawaited(cancelSub);
      client.close(force: true);
    }
  }

  static String _describe(Object e, Uri uri) {
    if (e is TimeoutException) return 'таймаут (${uri.host})';
    var msg = switch (e) {
      HttpException(:final message) => message,
      SocketException(:final message, :final osError) =>
        '$message${osError == null ? '' : ' (${osError.message})'}',
      TlsException(:final message) => message,
      _ => '',
    };
    msg = msg.replaceAll(RegExp(r'uri = \S+'), '').trim();
    if (msg.length > 160) msg = '${msg.substring(0, 160)}…';
    return '${e.runtimeType}${msg.isEmpty ? '' : ': $msg'} (${uri.host})';
  }
}
