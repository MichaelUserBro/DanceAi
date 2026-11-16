import 'package:dance_ai/analysis/device_video_preparer.dart';
import 'package:dance_ai/analysis/media/ffmpeg_media_tool.dart';
import 'package:dance_ai/analysis/media/media_tool.dart';
import 'package:dance_ai/analysis/video_preparer.dart';
import 'package:dance_ai/platform/video_picker.dart';
import 'package:dance_ai/ui/video_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_video_picker.dart';
import '../test_data.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('danceai/video_picker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  void answer(Object? Function(MethodCall) f) {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return f(call);
    });
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('AndroidVideoPicker', () {
    test('выбор возвращает content:// URI, имя и размер — без копирования',
        () async {
      answer((_) => {
            'uri': 'content://media/document/video%3A42',
            'name': 'VID_1.mp4',
            'size': 390000000,
          });
      final v = await AndroidVideoPicker().pick(danceId: 'samba');
      expect(v!.source, 'content://media/document/video%3A42');
      expect(v.isContentUri, isTrue);
      expect(v.name, 'VID_1.mp4');
      expect(v.sizeBytes, 390000000);
      expect(calls.single.method, 'pick');
      expect(calls.single.arguments, {'danceId': 'samba'});
    });

    test('отмена → null; ошибка платформы → понятное сообщение', () async {
      answer((_) => null);
      expect(await AndroidVideoPicker().pick(danceId: 'samba'), isNull);
      answer((_) => throw PlatformException(code: 'NO_PICKER'));
      await expectLater(
          AndroidVideoPicker().pick(danceId: 'samba'),
          throwsA(isA<VideoPickException>().having(
              (e) => e.message, 'message', contains('Не удалось открыть'))));
    });

    test('выбор после выгрузки приложения: танец и видео', () async {
      answer((_) => {
            'uri': 'content://x/1',
            'name': null,
            'size': null,
            'danceId': 'quickstep',
          });
      final r = await AndroidVideoPicker().takeRestored();
      expect(r!.danceId, 'quickstep');
      expect(r.video.source, 'content://x/1');
      expect(r.video.name, 'Видео');
      answer((_) => null);
      expect(await AndroidVideoPicker().takeRestored(), isNull);
    });

    test('освобождение не обращается к платформе (право временное)',
        () async {
      answer((_) => null);
      await AndroidVideoPicker().release(
          const PickedVideo(source: 'content://x/1', name: 'a'));
      expect(calls, isEmpty);
    });
  });

  group('VideoSession', () {
    final dance = loadTestAppData().criteria.dance('samba');
    const probe = VideoProbe(readable: true, hasAudio: true);

    test('новое видео освобождает прежнее, release — текущее', () async {
      final picker = FakeVideoPicker();
      final s = VideoSession(dance: dance, picker: picker);
      const a = PickedVideo(source: 'content://a', name: 'a');
      const b = PickedVideo(source: 'content://b', name: 'b');
      await s.setVideo(a, probe);
      await s.setVideo(b, probe);
      expect(picker.released, ['content://a']);
      expect(s.path, 'content://b');
      await s.release();
      expect(picker.released, ['content://a', 'content://b']);
      expect(s.hasVideo, isFalse);
    });
  });

  test('недоступный content:// (файл удалён, право потеряно) — '
      'не вылет, а «не читается»', () async {
    // Плагина FFmpeg в тесте нет — как и при недоступном URI, получение
    // SAF-параметра падает.
    await expectLater(const FfmpegMediaTool().probe('content://gone/1'),
        throwsA(isA<MediaToolException>()));
    final probe = await DeviceVideoPreparer().probe('content://gone/1');
    expect(probe.readable, isFalse);
  });
}
