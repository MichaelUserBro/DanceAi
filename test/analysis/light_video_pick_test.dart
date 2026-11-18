// Выбор варианта кодера облегчённой копии (spec 7.3): потолок битрейта,
// режимы битрейта h264_mediacodec, mpeg4 — только если H.264 не сработал.
import 'dart:io';

import 'package:dance_ai/analysis/media/media_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late String out;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('danceai_light_');
    out = '${dir.path}/light.mp4';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  const android = [
    'h264_mediacodec:cbr',
    'h264_mediacodec:vbr',
    'h264_mediacodec',
    'mpeg4',
  ];
  // 100 с: 1 000 000 байт = 80 кбит/с.
  const duration = 100.0;
  int bytesFor(int kbps) => kbps * 1000 * duration ~/ 8;

  /// Исход каждого варианта: кбит/с копии или null — кодер не сработал.
  ({Future<LightVideo> Function(String, String) encode, List<String> tried})
      fake(Map<String, int?> kbps) {
    final tried = <String>[];
    Future<LightVideo> encode(String spec, String path) async {
      tried.add(spec);
      final k = kbps[spec];
      if (k == null) throw MediaToolException('$spec: configure failed');
      File(path).writeAsBytesSync(List.filled(bytesFor(k), 0));
      return LightVideo(path: path, sizeBytes: bytesFor(k), codec: spec);
    }

    return (encode: encode, tried: tried);
  }

  Future<LightVideo> pick(Map<String, int?> kbps,
          {List<String> encoders = android, double? durationSec = duration}) =>
      pickLightVideo(
        encoders: encoders,
        outFile: out,
        maxTotalKbps: const LightVideoOptions().maxTotalKbps,
        durationSec: durationSec,
        encode: fake(kbps).encode,
      );

  List<String> files() =>
      [for (final f in dir.listSync()) f.uri.pathSegments.last]..sort();

  test('потолок: (500 + 64) × 1,5 ≈ 846 кбит/с', () {
    expect(const LightVideoOptions().maxTotalKbps, 846);
  });

  test('разбор варианта кодера', () {
    expect(parseEncoder('h264_mediacodec:cbr'),
        (codec: 'h264_mediacodec', mode: 'cbr'));
    expect(parseEncoder('h264_mf'), (codec: 'h264_mf', mode: null));
  });

  test('CBR держит битрейт — первый же вариант', () async {
    final f = fake({'h264_mediacodec:cbr': 600});
    final v = await pickLightVideo(
        encoders: android,
        outFile: out,
        maxTotalKbps: 846,
        durationSec: duration,
        encode: f.encode);
    expect(f.tried, ['h264_mediacodec:cbr']);
    expect(v.path, out);
    expect(v.codec, 'h264_mediacodec cbr (600 кбит/с)');
    expect(files(), ['light.mp4']);
  });

  test('CBR не поддерживается → VBR', () async {
    final v = await pick({'h264_mediacodec:cbr': null, 'h264_mediacodec:vbr': 650});
    expect(v.codec, startsWith('h264_mediacodec vbr'));
    expect(files(), ['light.mp4']);
  });

  test('CBR выше потолка, VBR в норме → VBR, пробный файл удалён', () async {
    final v = await pick({'h264_mediacodec:cbr': 1400, 'h264_mediacodec:vbr': 700});
    expect(v.codec,
        'h264_mediacodec vbr (700 кбит/с; не уложились: h264_mediacodec cbr 1400)');
    expect(v.sizeBytes, bytesFor(700));
    expect(File(out).lengthSync(), bytesFor(700));
    expect(files(), ['light.mp4']);
  });

  test('H.264 не держит битрейт ни в одном режиме → самая маленькая копия '
      'H.264, mpeg4 не пробуется', () async {
    final f = fake({
      'h264_mediacodec:cbr': 1500,
      'h264_mediacodec:vbr': 1200,
      'h264_mediacodec': 1400,
      'mpeg4': 500,
    });
    final v = await pickLightVideo(
        encoders: android,
        outFile: out,
        maxTotalKbps: 846,
        durationSec: duration,
        encode: f.encode);
    expect(f.tried, isNot(contains('mpeg4')));
    expect(v.sizeBytes, bytesFor(1200));
    expect(v.codec, startsWith('h264_mediacodec vbr (1200 кбит/с; выше потолка 846'));
    expect(v.codec, contains('h264_mediacodec cbr 1500'));
    expect(files(), ['light.mp4']);
  });

  test('H.264 не сработал совсем → mpeg4', () async {
    final v = await pick({'mpeg4': 550});
    expect(v.codec, 'mpeg4 (550 кбит/с)');
    expect(files(), ['light.mp4']);
  });

  test('ни один кодер не сработал → ошибка последнего', () async {
    await expectLater(
        pick({}),
        throwsA(isA<MediaToolException>()
            .having((e) => e.message, 'message', contains('mpeg4'))));
    expect(files(), isEmpty);
  });

  test('длительность неизвестна — первый сработавший', () async {
    final v = await pick({'h264_mediacodec:cbr': 3000}, durationSec: null);
    expect(v.codec, 'h264_mediacodec cbr');
  });

  test('Windows: h264_mf выше потолка — остаётся h264_mf, без mpeg4', () async {
    final v = await pick({'h264_mf': 1000, 'mpeg4': 500},
        encoders: const ['h264_mf', 'mpeg4']);
    expect(v.codec, startsWith('h264_mf (1000 кбит/с; выше потолка'));
  });
}
