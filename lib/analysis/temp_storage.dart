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

  /// При запуске: остатки прошлых анализов (если приложение было закрыто
  /// посреди анализа) и, на Android, копии видео, которые делали прежние
  /// версии приложения (сейчас видео не копируется).
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
