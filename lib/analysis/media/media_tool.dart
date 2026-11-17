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
  /// Кодек — первый сработавший из [LightVideoOptions.encoders].
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

  /// Видеокодеры по порядку; пусто — по умолчанию для платформы.
  final List<String> encoders;
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
