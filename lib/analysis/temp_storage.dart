import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Временные файлы анализа (spec 7.4 п. 5, 8): всё — во временной папке
/// приложения и удаляется сразу после анализа.
class TempStorage {
  TempStorage({Future<Directory> Function()? root, bool? isAndroid})
      : _root = root ?? getTemporaryDirectory,
        _isAndroid = isAndroid ?? Platform.isAndroid;

  final Future<Directory> Function() _root;
  final bool _isAndroid;

  static const _workFolder = 'danceai_work';
  static final _uuidLike = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false);

  /// Новая папка для одного анализа.
  Future<Directory> createWorkDir() async {
    final root = await _root();
    final dir = Directory(
        '${root.path}${Platform.pathSeparator}$_workFolder${Platform.pathSeparator}'
        '${DateTime.now().microsecondsSinceEpoch}');
    return dir.create(recursive: true);
  }

  Future<void> deleteDir(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Файл мог быть занят — повторим при следующем запуске (cleanupStale).
    }
  }

  /// На Android выбранное видео — копия во временной папке приложения
  /// ({cache}/{uuid}/{файл}); её удаляем. На Windows это файл пользователя —
  /// его не трогаем никогда.
  Future<void> releasePickedVideo(String path) async {
    if (!_isAndroid) return;
    final root = (await _root()).absolute.path;
    final file = File(path).absolute;
    final parent = file.parent;
    if (!file.path.startsWith(root)) return;
    try {
      if (parent.path != root && _uuidLike.hasMatch(_name(parent.path))) {
        await parent.delete(recursive: true);
      } else if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Не критично: подчистит cleanupStale при следующем запуске.
    }
  }

  /// При запуске: остатки прошлых анализов (если приложение было закрыто
  /// посреди анализа) и, на Android, старые копии выбранных видео.
  Future<void> cleanupStale() async {
    final root = await _root();
    await deleteDir(Directory('${root.path}${Platform.pathSeparator}$_workFolder'));
    if (!_isAndroid || !await root.exists()) return;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is Directory && _uuidLike.hasMatch(_name(entity.path))) {
        await deleteDir(entity);
      }
    }
  }

  static String _name(String path) =>
      path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last;
}
