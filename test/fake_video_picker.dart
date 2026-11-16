import 'package:dance_ai/platform/video_picker.dart';

/// Выбор видео без платформы: заранее заданный ответ, учёт освобождений.
class FakeVideoPicker implements VideoPicker {
  FakeVideoPicker({this.next, this.restored, this.error});

  PickedVideo? next;
  RestoredPick? restored;
  VideoPickException? error;
  final released = <String>[];
  final picks = <String>[];

  @override
  Future<PickedVideo?> pick({required String danceId}) async {
    picks.add(danceId);
    if (error != null) throw error!;
    return next;
  }

  @override
  Future<RestoredPick?> takeRestored() async {
    final r = restored;
    restored = null;
    return r;
  }

  @override
  Future<void> release(PickedVideo video) async => released.add(video.source);
}
