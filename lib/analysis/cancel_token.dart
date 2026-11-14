import 'dart:async';

/// Анализ отменён пользователем.
class AnalysisCancelled implements Exception {
  const AnalysisCancelled();
  @override
  String toString() => 'Анализ отменён';
}

/// Отмена долгой операции: подготовка видео, запрос к ИИ.
class CancelToken {
  bool _cancelled = false;
  final _completer = Completer<void>();

  bool get isCancelled => _cancelled;

  /// Завершается в момент отмены — удобно для гонки с долгим ожиданием.
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _completer.complete();
  }

  void throwIfCancelled() {
    if (_cancelled) throw const AnalysisCancelled();
  }

  /// Пауза, которую можно прервать отменой.
  Future<void> delay(Duration d) async {
    await Future.any([Future<void>.delayed(d), whenCancelled]);
    throwIfCancelled();
  }
}
