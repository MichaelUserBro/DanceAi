import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// Выбранное видео. [source] — путь к файлу (Windows) или `content://` URI
/// (Android). Видео не копируется и не читается в память при выборе.
class PickedVideo {
  const PickedVideo({required this.source, required this.name, this.sizeBytes});

  final String source;
  final String name;
  final int? sizeBytes;

  bool get isContentUri => source.startsWith('content://');
}

/// Выбор, результат которого пришёл после того, как Android выгрузил
/// приложение (пока был открыт системный выбор).
class RestoredPick {
  const RestoredPick({required this.danceId, required this.video});
  final String danceId;
  final PickedVideo video;
}

/// Ошибка выбора — понятный текст на русском, без подробностей.
class VideoPickException implements Exception {
  const VideoPickException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract interface class VideoPicker {
  /// null — пользователь отменил выбор.
  Future<PickedVideo?> pick({required String danceId});

  /// Невыданный выбор после перезапуска процесса (Android). Один раз.
  Future<RestoredPick?> takeRestored();

  /// Видео больше не нужно (анализ закончен или выбрано другое):
  /// приложение забывает его. Копий нет, удалять нечего.
  Future<void> release(PickedVideo video);

  factory VideoPicker.platform() =>
      Platform.isAndroid ? AndroidVideoPicker() : FileSelectorVideoPicker();
}

/// Android: системный выбор документа через свой канал (MainActivity.kt).
class AndroidVideoPicker implements VideoPicker {
  AndroidVideoPicker({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('danceai/video_picker');

  final MethodChannel _channel;

  static PickedVideo? _parse(Object? raw) {
    if (raw is! Map) return null;
    final uri = raw['uri'];
    if (uri is! String) return null;
    return PickedVideo(
      source: uri,
      name: (raw['name'] as String?) ?? 'Видео',
      sizeBytes: (raw['size'] as num?)?.toInt(),
    );
  }

  @override
  Future<PickedVideo?> pick({required String danceId}) async {
    try {
      return _parse(await _channel
          .invokeMethod<Object?>('pick', {'danceId': danceId}));
    } on PlatformException {
      throw const VideoPickException(
          'Не удалось открыть выбор файла. Попробуйте ещё раз.');
    }
  }

  @override
  Future<RestoredPick?> takeRestored() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('takeRestored');
      final video = _parse(raw);
      final danceId = raw is Map ? raw['danceId'] : null;
      if (video == null || danceId is! String) return null;
      return RestoredPick(danceId: danceId, video: video);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Право на URI временное (из результата выбора) — освобождать нечего:
  /// приложение просто забывает URI.
  @override
  Future<void> release(PickedVideo video) async {}
}

/// Windows: обычный выбор файла — путь к файлу пользователя, без копий.
class FileSelectorVideoPicker implements VideoPicker {
  static const _types = XTypeGroup(
    label: 'Видео',
    extensions: ['mp4', 'mov', 'm4v', '3gp', 'mkv', 'webm', 'avi'],
    mimeTypes: ['video/*'],
    uniformTypeIdentifiers: ['public.movie'],
  );

  @override
  Future<PickedVideo?> pick({required String danceId}) async {
    try {
      final file = await openFile(acceptedTypeGroups: const [_types]);
      if (file == null) return null;
      return PickedVideo(source: file.path, name: file.name);
    } on Exception {
      throw const VideoPickException(
          'Не удалось открыть выбор файла. Попробуйте ещё раз.');
    }
  }

  @override
  Future<RestoredPick?> takeRestored() async => null;

  @override
  Future<void> release(PickedVideo video) async {}
}
