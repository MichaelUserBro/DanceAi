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
}
