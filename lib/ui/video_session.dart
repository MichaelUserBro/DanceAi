import 'package:flutter/foundation.dart';

import '../analysis/temp_storage.dart';
import '../analysis/video_preparer.dart';
import '../data/criteria.dart';

/// Выбранное видео на время одного «захода»: экран «Видео» → анализ →
/// отчёт или ошибка. После успешного анализа и при уходе с экрана «Видео»
/// копия видео (на Android) удаляется — видео не хранится.
class VideoSession extends ChangeNotifier {
  VideoSession({required this.dance, required TempStorage tempStorage})
      : _temp = tempStorage;

  final Dance dance;
  final TempStorage _temp;

  String? _path;
  String? _name;
  VideoProbe? _probe;

  /// Просьба с экранов ошибки/предупреждения открыть выбор другого видео.
  VoidCallback? onChooseOther;

  String? get path => _path;
  String? get name => _name;
  VideoProbe? get probe => _probe;
  bool get hasVideo => _path != null;

  Future<void> setVideo(String path, String name, VideoProbe probe) async {
    await release();
    _path = path;
    _name = name;
    _probe = probe;
    notifyListeners();
  }

  /// Удалить копию видео (если это копия во временной папке) и забыть её.
  Future<void> release() async {
    final old = _path;
    if (old == null) return;
    _path = null;
    _name = null;
    _probe = null;
    notifyListeners();
    await _temp.releasePickedVideo(old);
  }
}
