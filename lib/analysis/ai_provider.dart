import 'cancel_token.dart';
import 'video_preparer.dart';

/// Что адаптер умеет и какие у модели лимиты (spec 7.3).
class AiCapabilities {
  const AiCapabilities({
    required this.supportsVideo,
    this.frameOptions = const FrameOptions(),
  });

  /// Адаптер умеет передавать видео целиком. Если нет — переключатель
  /// «Модель принимает видео со звуком» недоступен.
  final bool supportsVideo;
  final FrameOptions frameOptions;
}

/// Материал + промпт → текст ответа. Общий для всех адаптеров.
class AiRequest {
  const AiRequest({
    required this.danceId,
    required this.systemPrompt,
    required this.userPrompt,
    required this.mode,
    required this.material,
    required this.reportSchema,
    this.retryNote,
    this.previousResponse,
  });

  final String danceId;
  final String systemPrompt;
  final String userPrompt;
  final SubmissionMode mode;
  final PreparedMaterial material;

  /// Для структурированного вывода, если провайдер его поддерживает.
  final Map<String, dynamic> reportSchema;

  /// Повторный запрос: описание ошибок проверки и прошлый ответ.
  final String? retryNote;
  final String? previousResponse;

  bool get isRetry => retryNote != null;

  AiRequest retry({required String note, required String previous}) =>
      AiRequest(
        danceId: danceId,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        mode: mode,
        material: material,
        reportSchema: reportSchema,
        retryNote: note,
        previousResponse: previous,
      );
}

enum AiPhase { sending, waiting }

enum AiErrorKind { invalidKey, rateLimit, network, tooLarge, server, notConfigured }

/// Ошибка API. Текст никогда не содержит ключа.
class AiException implements Exception {
  const AiException(this.kind, [this.detail]);

  final AiErrorKind kind;

  /// Технические подробности для «Для разработчика» (без ключа).
  final String? detail;

  @override
  String toString() => 'AiException($kind${detail == null ? '' : ': $detail'})';
}

/// Адаптер провайдера ИИ. Интерфейс приложения не знает, какой работает.
abstract interface class AiProvider {
  /// Короткое имя для экрана анализа.
  String get displayName;

  AiCapabilities get capabilities;

  /// Бросает [AiException] при ошибках API и [AnalysisCancelled] при отмене.
  Future<String> analyze(
    AiRequest request, {
    required void Function(AiPhase) onPhase,
    required CancelToken cancel,
  });
}
