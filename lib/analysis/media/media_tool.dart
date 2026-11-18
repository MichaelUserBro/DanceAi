import 'dart:io';

import '../cancel_token.dart';

/// Сведения о файле от ffprobe.
class MediaInfo {
  const MediaInfo({
    required this.durationSec,
    required this.hasAudio,
    required this.hasVideo,
    this.width,
    this.height,
  });

  final double? durationSec;
  final bool hasAudio;
  final bool hasVideo;
  final int? width;
  final int? height;
}

/// Ошибка чтения или декодирования (код и последняя строка лога —
/// только для «Для разработчика»; путей к ключам здесь не бывает).
class MediaToolException implements Exception {
  const MediaToolException(this.message);
  final String message;

  @override
  String toString() => 'MediaToolException: $message';
}

/// Низкоуровневые операции с видео. Настоящая реализация — FFmpeg
/// ([FfmpegMediaTool]); в тестах — подделка, пишущая файлы в папку анализа.
///
/// [input] — путь к файлу или `content://` URI (Android).
abstract interface class MediaTool {
  /// null — файл не читается как видео.
  Future<MediaInfo?> probe(String input);

  /// Кадры с частотой [fps]: i-й файл (по имени) — момент i / fps.
  /// Длинная сторона — не больше [maxLongSidePx]. Возвращает пути по порядку.
  Future<List<String>> extractFrames({
    required String input,
    required String outDir,
    required double fps,
    required int maxLongSidePx,
    required double? durationSec,
    required void Function(double fraction) onProgress,
    required CancelToken cancel,
  });

  /// Звук: моно, [sampleRate] Гц, 32-битный float little-endian без заголовка.
  Future<void> extractAudio({
    required String input,
    required String outFile,
    required int sampleRate,
    required double? durationSec,
    required void Function(double fraction) onProgress,
    required CancelToken cancel,
  });

  /// Облегчённая копия для подачи видео целиком (spec 7.3): mp4, короткая
  /// сторона не больше [shortSidePx], [fps] кадр/с, звук AAC моно.
  /// Вариант кодера — по [pickLightVideo] из [LightVideoOptions.encoders].
  Future<LightVideo> transcodeLight({
    required String input,
    required String outFile,
    required LightVideoOptions options,
    required double? durationSec,
    required void Function(double fraction) onProgress,
    required CancelToken cancel,
  });
}

/// Параметры облегчённой копии видео.
class LightVideoOptions {
  const LightVideoOptions({
    this.shortSidePx = 480,
    this.fps = 15,
    this.videoKbps = 500,
    this.audioKbps = 64,
    this.encoders = const [],
  });

  final int shortSidePx;
  final int fps;
  final int videoKbps;
  final int audioKbps;

  /// Варианты видеокодера по порядку: `кодек` или `кодек:режим битрейта`
  /// (`h264_mediacodec:cbr`); пусто — по умолчанию для платформы.
  final List<String> encoders;

  /// Потолок битрейта копии (видео + звук): выше — кодер не держит заданный
  /// битрейт, пробуем следующий вариант того же кодека.
  int get maxTotalKbps => ((videoKbps + audioKbps) * 1.5).round();
}

/// `h264_mediacodec:cbr` → кодек и режим битрейта (null — по умолчанию).
({String codec, String? mode}) parseEncoder(String spec) {
  final i = spec.indexOf(':');
  return i < 0
      ? (codec: spec, mode: null)
      : (codec: spec.substring(0, i), mode: spec.substring(i + 1));
}

/// Битрейт файла, кбит/с; null — длительность неизвестна.
int? fileKbps(int sizeBytes, double? durationSec) =>
    durationSec == null || durationSec <= 0
        ? null
        : (sizeBytes * 8 / durationSec / 1000).round();

/// Выбор варианта кодера для облегчённой копии (spec 7.3).
/// Варианты пробуются по порядку; первый, чья копия не выше
/// [maxTotalKbps], — результат. Копия выше потолка запоминается, и дальше
/// пробуются только варианты того же кодека (другой кодек, например `mpeg4`,
/// — только если этот не сработал совсем). Ни один не уложился — самая
/// маленькая копия. [encode] пишет копию в переданный путь; итог — в
/// [outFile], пробные файлы удаляются.
Future<LightVideo> pickLightVideo({
  required List<String> encoders,
  required String outFile,
  required int maxTotalKbps,
  required double? durationSec,
  required Future<LightVideo> Function(String encoder, String path) encode,
}) async {
  LightVideo? best;
  String? bestSpec;
  final rejected = <(String, int)>[];
  MediaToolException? last;
  String label(String spec) => spec.replaceAll(':', ' ');

  Future<void> remove(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  Future<LightVideo> finish(LightVideo v, String spec,
      {required bool over}) async {
    if (v.path != outFile) {
      await remove(outFile);
      await File(v.path).rename(outFile);
    }
    final kbps = fileKbps(v.sizeBytes, durationSec);
    final others = [
      for (final r in rejected)
        if (r.$1 != spec) '${label(r.$1)} ${r.$2}',
    ];
    final notes = [
      if (kbps != null) '$kbps кбит/с',
      if (over) 'выше потолка $maxTotalKbps',
      if (others.isNotEmpty) 'не уложились: ${others.join(', ')}',
    ];
    return LightVideo(
      path: outFile,
      sizeBytes: v.sizeBytes,
      codec: notes.isEmpty ? label(spec) : '${label(spec)} (${notes.join('; ')})',
      width: v.width,
      height: v.height,
    );
  }

  for (var i = 0; i < encoders.length; i++) {
    final spec = encoders[i];
    final kept = bestSpec;
    if (kept != null && parseEncoder(spec).codec != parseEncoder(kept).codec) {
      break;
    }
    final path = i == 0 ? outFile : '$outFile.try$i';
    final LightVideo v;
    try {
      v = await encode(spec, path);
    } on MediaToolException catch (e) {
      last = e;
      await remove(path);
      continue;
    }
    final kbps = fileKbps(v.sizeBytes, durationSec);
    if (kbps == null || kbps <= maxTotalKbps) {
      final b = best;
      if (b != null) await remove(b.path);
      return finish(v, spec, over: false);
    }
    rejected.add((spec, kbps));
    final b = best;
    if (b == null || v.sizeBytes < b.sizeBytes) {
      if (b != null) await remove(b.path);
      best = v;
      bestSpec = spec;
    } else {
      await remove(v.path);
    }
  }
  final b = best;
  if (b != null) return finish(b, bestSpec!, over: true);
  throw last ?? const MediaToolException('нет видеокодера');
}

/// Результат: путь, размер и кодек (для «Для разработчика»).
class LightVideo {
  const LightVideo({
    required this.path,
    required this.sizeBytes,
    required this.codec,
    this.width,
    this.height,
  });

  final String path;
  final int sizeBytes;
  final String codec;
  final int? width;
  final int? height;
}
