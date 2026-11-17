// Облегчённая копия видео для режима «видео со звуком»: какие кодеки
// работают в нашей сборке FFmpeg, размер и время. Видео — локальные:
//   Windows: test_videos/ (или --dart-define=VIDEO_DIR=...)
//   Android: <внешняя папка приложения>/bench
// Копии пишутся во временную папку и удаляются; при KEEP_DIR — копируются
// туда (для ручной проверки, что модели их принимают).
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
        final out = '${tmp.path}/${codec}_$name';
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
              'audio ${back?.hasAudio} | ${sw.elapsedMilliseconds} ms');
          ok[codec] = (ok[codec] ?? 0) + 1;
          expect(back?.hasAudio, isTrue);
          if (_keepDir.isNotEmpty) {
            await File(r.path).copy('$_keepDir/${codec}_$name');
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
