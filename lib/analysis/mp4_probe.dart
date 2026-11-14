import 'dart:io';
import 'dart:typed_data';

/// Результат разбора контейнера MP4/MOV.
class Mp4Info {
  const Mp4Info({this.durationSec, required this.hasAudio, required this.hasVideo});

  final double? durationSec;
  final bool hasAudio;
  final bool hasVideo;
}

/// Разбор MP4/MOV (ISO BMFF) на чистом Dart: длительность из `mvhd`,
/// дорожки — по `hdlr` (`soun` — звук, `vide` — видео).
/// Возвращает null, если файл не похож на MP4/MOV.
/// Читает только заголовки атомов и `moov`, не всё видео.
Future<Mp4Info?> probeMp4(String path) async {
  final file = File(path);
  final raf = await file.open();
  try {
    final length = await raf.length();
    var offset = 0;
    var sawKnownTopBox = false;
    while (offset + 8 <= length) {
      await raf.setPosition(offset);
      final header = await raf.read(16);
      if (header.length < 8) return null;
      final bd = ByteData.sublistView(header);
      var size = bd.getUint32(0);
      final type = String.fromCharCodes(header.sublist(4, 8));
      var headerSize = 8;
      if (size == 1) {
        if (header.length < 16) return null;
        size = bd.getUint64(8);
        headerSize = 16;
      } else if (size == 0) {
        size = length - offset;
      }
      if (size < headerSize) return null;
      if (!_isPrintable(type)) return null;
      if (const {'ftyp', 'moov', 'mdat', 'free', 'skip', 'wide', 'uuid', 'pnot'}
          .contains(type)) {
        sawKnownTopBox = true;
      }
      if (type == 'moov') {
        const maxMoov = 64 * 1024 * 1024;
        final bodySize = size - headerSize;
        if (bodySize > maxMoov) return null;
        await raf.setPosition(offset + headerSize);
        final body = await raf.read(bodySize);
        return _parseMoov(body);
      }
      if (offset == 0 && !sawKnownTopBox) return null;
      offset += size;
    }
    return null;
  } finally {
    await raf.close();
  }
}

bool _isPrintable(String fourcc) =>
    fourcc.codeUnits.every((c) => c >= 0x20 && c <= 0x7E);

/// Синхронная версия для тестов и Isolate.run над байтами `moov`.
Mp4Info _parseMoov(Uint8List moov) {
  double? duration;
  var hasAudio = false;
  var hasVideo = false;

  void walk(Uint8List data, int start, int end, List<String> parents) {
    final bd = ByteData.sublistView(data);
    var p = start;
    while (p + 8 <= end) {
      var size = bd.getUint32(p);
      final type = String.fromCharCodes(data.sublist(p + 4, p + 8));
      var header = 8;
      if (size == 1) {
        if (p + 16 > end) return;
        size = bd.getUint64(p + 8);
        header = 16;
      } else if (size == 0) {
        size = end - p;
      }
      if (size < header || p + size > end) return;
      final bodyStart = p + header;
      switch (type) {
        case 'mvhd':
          final version = data[bodyStart];
          if (version == 1 && bodyStart + 32 <= end) {
            final timescale = bd.getUint32(bodyStart + 20);
            final dur = bd.getUint64(bodyStart + 24);
            if (timescale > 0) duration = dur / timescale;
          } else if (bodyStart + 20 <= end) {
            final timescale = bd.getUint32(bodyStart + 12);
            final dur = bd.getUint32(bodyStart + 16);
            if (timescale > 0) duration = dur / timescale;
          }
        case 'hdlr':
          if (parents.isNotEmpty && parents.last == 'mdia' &&
              bodyStart + 12 <= end) {
            final handler =
                String.fromCharCodes(data.sublist(bodyStart + 8, bodyStart + 12));
            if (handler == 'soun') hasAudio = true;
            if (handler == 'vide') hasVideo = true;
          }
        case 'trak' || 'mdia':
          walk(data, bodyStart, p + size, [...parents, type]);
      }
      p += size;
    }
  }

  walk(moov, 0, moov.length, const ['moov']);
  return Mp4Info(durationSec: duration, hasAudio: hasAudio, hasVideo: hasVideo);
}

/// Для тестов: разбор готовых байтов `moov` (без заголовка самого moov).
Mp4Info parseMoovForTest(Uint8List moovBody) => _parseMoov(moovBody);
