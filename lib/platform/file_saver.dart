import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// Сохранение файла по выбору пользователя («Сохранить JSON»).
/// Android — системный диалог через свой канал (ACTION_CREATE_DOCUMENT),
/// Windows — диалог «Сохранить как» из file_selector. Без новых пакетов.
abstract interface class FileSaver {
  /// true — сохранено; false — пользователь отменил.
  Future<bool> save({
    required String name,
    required Uint8List bytes,
    String mime = 'application/json',
  });

  factory FileSaver.platform() =>
      Platform.isAndroid ? const _AndroidFileSaver() : const _DesktopFileSaver();
}

class _AndroidFileSaver implements FileSaver {
  const _AndroidFileSaver();
  static const _channel = MethodChannel('danceai/files');

  @override
  Future<bool> save({
    required String name,
    required Uint8List bytes,
    String mime = 'application/json',
  }) async =>
      await _channel.invokeMethod<bool>(
          'save', {'name': name, 'mime': mime, 'bytes': bytes}) ??
      false;
}

class _DesktopFileSaver implements FileSaver {
  const _DesktopFileSaver();

  @override
  Future<bool> save({
    required String name,
    required Uint8List bytes,
    String mime = 'application/json',
  }) async {
    final location = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (location == null) return false;
    await File(location.path).writeAsBytes(bytes, flush: true);
    return true;
  }
}
