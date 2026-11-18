// Облегчённая копия видео для режима «видео со звуком»: какие кодеки
// работают в нашей сборке FFmpeg, размер и время. Видео — локальные:
//   Windows: test_videos/ (или --dart-define=VIDEO_DIR=...)
//   Android: <внешняя папка приложения>/bench
// Копии пишутся во временную папку и удаляются; при KEEP_DIR — копируются
// туда (для ручной проверки, что модели их принимают).
// WAIT_SEC — ждать в папке видео файл-метку `ready` (эмулятор: видео
// копируются через `adb shell run-as` после установки приложения, а
// `flutter test` удаляет приложение после прогона).
//
//   flutter test integration_test/light_video_test.dart -d windows
//
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:dance_ai/analysis/cancel_token.dart';
import 'package:dance_ai/analysis/media/ffmpeg_media_tool.dart';
import 'package:dance_ai/analysis/media/media_tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _videoDirDefine = String.fromEnvironment('VIDEO_DIR');
const _keepDir = String.fromEnvironment('KEEP_DIR');
const _waitSec = int.fromEnvironment('WAIT_SEC');

Future<Directory> _videoDir() async {
  if (_videoDirDefine.isNotEmpty) return Directory(_videoDirDefine);
  if (Platform.isAndroid) {
    return Directory('${(await getExternalStorageDirectory())!.path}/bench');
  }
  return Directory('test_videos');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('облегчённая копия: каждый кодек платформы', (tester) async {
    final dir = await _videoDir();
    if (_waitSec > 0) {
      print('LIGHT жду видео и метку ready в ${dir.path}');
      final end = DateTime.now().add(const Duration(seconds: _waitSec));
      while (!File('${dir.path}/ready').existsSync() &&
          DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    final files = dir.existsSync()
        ? (dir.listSync().whereType<File>().where((f) =>
                RegExp(r'\.(mp4|mov)$', caseSensitive: false).hasMatch(f.path))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
        : <File>[];
    if (files.isEmpty) {
      print('LIGHT пропущено: нет видео в ${dir.path}');
      return;
    }
    const tool = FfmpegMediaTool();
    final tmp = await Directory.systemTemp.createTemp('danceai_light_');
    addTearDown(() => tmp.delete(recursive: true));
    final ok = <String, int>{};
    for (final codec in FfmpegMediaTool.defaultEncoders) {
      for (final file in files) {
        final name = file.uri.pathSegments.last;
        final info = await tool.probe(file.path);
        final safe = codec.replaceAll(':', '-');
        final out = '${tmp.path}/${safe}_$name';
        final sw = Stopwatch()..start();
        try {
          final r = await tool.transcodeLight(
            input: file.path,
            outFile: out,
            options: LightVideoOptions(encoders: [codec]),
            durationSec: info?.durationSec,
            onProgress: (_) {},
            cancel: CancelToken(),
          );
          sw.stop();
          final back = await tool.probe(r.path);
          print('LIGHT $codec | $name | ${info?.width}x${info?.height} '
              '${info?.durationSec?.toStringAsFixed(1)} s '
              '${(file.lengthSync() / 1e6).toStringAsFixed(1)} MB → '
              '${r.width}x${r.height} ${(r.sizeBytes / 1e6).toStringAsFixed(2)} MB '
              'audio ${back?.hasAudio} | ${r.codec} | ${sw.elapsedMilliseconds} ms');
          ok[codec] = (ok[codec] ?? 0) + 1;
          expect(back?.hasAudio, isTrue);
          if (_keepDir.isNotEmpty) {
            await File(r.path).copy('$_keepDir/${safe}_$name');
          }
          await File(r.path).delete();
        } on MediaToolException catch (e) {
          print('LIGHT $codec | $name | ОШИБКА ${e.message}');
        }
      }
    }
    print('LIGHT итог: $ok');
    expect(ok.values.fold(0, (a, b) => a + b), greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 30)));
}
