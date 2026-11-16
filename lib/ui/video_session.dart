import 'package:flutter/foundation.dart';

import '../analysis/video_preparer.dart';
import '../data/criteria.dart';
import '../platform/video_picker.dart';

/// Выбранное видео на время одного «захода»: экран «Видео» → анализ →
/// отчёт или ошибка. Видео не копируется: на Android это `content://` URI,
/// на Windows — путь к файлу пользователя. После анализа и при уходе
/// с экрана «Видео» право на URI освобождается — видео не хранится.
class VideoSession extends ChangeNotifier {
  VideoSession({required this.dance, required this._picker});

  final Dance dance;
  final VideoPicker _picker;

  PickedVideo? _video;
  VideoProbe? _probe;

  /// Просьба с экранов ошибки/предупреждения открыть выбор другого видео.
  VoidCallback? onChooseOther;

  PickedVideo? get video => _video;

  /// Путь к файлу или `content://` URI — FFmpeg и превью читают напрямую.
  String? get path => _video?.source;
  String? get name => _video?.name;
  VideoProbe? get probe => _probe;
  bool get hasVideo => _video != null;

  Future<void> setVideo(PickedVideo video, VideoProbe probe) async {
    final old = _video;
    _video = video;
    _probe = probe;
    notifyListeners();
    if (old != null && old.source != video.source) await _picker.release(old);
  }

  /// Забыть видео и освободить право на него.
  Future<void> release() async {
    final old = _video;
    if (old == null) return;
    _video = null;
    _probe = null;
    notifyListeners();
    await _picker.release(old);
  }
}
