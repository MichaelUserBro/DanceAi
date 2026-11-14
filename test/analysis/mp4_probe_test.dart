import 'dart:io';
import 'dart:typed_data';

import 'package:dance_ai/analysis/basic_video_preparer.dart';
import 'package:dance_ai/analysis/mp4_probe.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List box(String type, List<int> body) {
  final b = BytesBuilder();
  final size = ByteData(4)..setUint32(0, 8 + body.length);
  b.add(size.buffer.asUint8List());
  b.add(type.codeUnits);
  b.add(body);
  return b.toBytes();
}

List<int> mvhd({required int timescale, required int duration}) {
  final d = ByteData(100);
  d.setUint8(0, 0); // version 0
  d.setUint32(12, timescale);
  d.setUint32(16, duration);
  return d.buffer.asUint8List();
}

List<int> trak(String handler) => box('trak', box('mdia', [
      ...box('mdhd', List.filled(24, 0)),
      ...box('hdlr', [0, 0, 0, 0, 0, 0, 0, 0, ...handler.codeUnits, ...List.filled(12, 0)]),
    ]));

Uint8List mp4({required bool audio}) => Uint8List.fromList([
      ...box('ftyp', 'isom\x00\x00\x02\x00isomiso2mp41'.codeUnits),
      ...box('mdat', List.filled(64, 7)),
      ...box('moov', [
        ...box('mvhd', mvhd(timescale: 1000, duration: 93400)),
        ...trak('vide'),
        if (audio) ...trak('soun'),
      ]),
    ]);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mp4_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('длительность и звук (moov в конце файла)', () async {
    final f = File('${dir.path}/a.mp4')..writeAsBytesSync(mp4(audio: true));
    final info = await probeMp4(f.path);
    expect(info, isNotNull);
    expect(info!.durationSec, closeTo(93.4, 1e-9));
    expect(info.hasAudio, isTrue);
    expect(info.hasVideo, isTrue);
  });

  test('без звуковой дорожки', () async {
    final f = File('${dir.path}/b.mp4')..writeAsBytesSync(mp4(audio: false));
    final info = await probeMp4(f.path);
    expect(info!.hasAudio, isFalse);
  });

  test('не MP4 → null', () async {
    final f = File('${dir.path}/c.webm')
      ..writeAsBytesSync([0x1A, 0x45, 0xDF, 0xA3, ...List.filled(40, 0)]);
    expect(await probeMp4(f.path), isNull);
  });

  test('BasicVideoPreparer.probe', () async {
    final f = File('${dir.path}/a.mp4')..writeAsBytesSync(mp4(audio: false));
    final p = await const BasicVideoPreparer().probe(f.path);
    expect(p.readable, isTrue);
    expect(p.hasAudio, isFalse);
    expect(p.durationSec, closeTo(93.4, 1e-9));
    final missing =
        await const BasicVideoPreparer().probe('${dir.path}/nope.mp4');
    expect(missing.readable, isFalse);
  });
}
