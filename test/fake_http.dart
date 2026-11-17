import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dance_ai/analysis/cancel_token.dart';
import 'package:dance_ai/analysis/providers/http_transport.dart';

/// Подменённый HTTP: записывает запросы, отвечает по сценарию.
class FakeHttp implements HttpTransport {
  FakeHttp(this.handler);

  /// Ответ на запрос (или исключение).
  final FutureOr<HttpResult> Function(HttpCall call, int index) handler;
  final calls = <HttpCall>[];

  /// Завершается, когда начат запрос, который ждёт отмены ([hang]).
  final hanging = Completer<void>();

  @override
  Future<HttpResult> send(
    HttpCall call, {
    required CancelToken cancel,
    void Function(double fraction)? onUpload,
    void Function(int receivedBytes)? onReceive,
  }) async {
    cancel.throwIfCancelled();
    calls.add(call);
    onUpload?.call(0.5);
    onUpload?.call(1);
    // Как настоящий транспорт: отмена обрывает ожидание ответа сразу.
    final r = await Future.any<HttpResult?>([
      Future.sync(() => handler(call, calls.length - 1)),
      cancel.whenCancelled.then((_) => null),
    ]);
    cancel.throwIfCancelled();
    if (r == null) throw StateError('ответа нет');
    onReceive?.call(r.body.length);
    return r;
  }

  /// Тело запроса как JSON.
  static Map<String, dynamic> body(HttpCall c) =>
      jsonDecode(utf8.decode(c.body)) as Map<String, dynamic>;
}

HttpResult jsonResult(int status, Object body, [Map<String, String> headers = const {}]) =>
    HttpResult(status, headers, Uint8List.fromList(utf8.encode(jsonEncode(body))));

HttpResult textResult(int status, String body, [Map<String, String> headers = const {}]) =>
    HttpResult(status, headers, Uint8List.fromList(utf8.encode(body)));
