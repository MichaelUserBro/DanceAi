import 'cancel_token.dart';
import 'video_preparer.dart';

/// Что адаптер умеет и какие у модели лимиты (spec 7.3). Пайплайн решает
/// только по этим полям — без знания, какой провайдер работает.
class AiCapabilities {
  const AiCapabilities({
    required this.supportsVideo,
    this.frameOptions = const FrameOptions(),
    this.maxVideoBytes,
    this.videoFpsConfigurable = false,
    this.thinkingConfigurable = false,
    this.streamsResponse = false,
  });

  /// Адаптер умеет передавать видео целиком. Если нет — переключатель
  /// «Модель принимает видео со звуком» недоступен.
  final bool supportsVideo;
  final FrameOptions frameOptions;

  /// Наибольший размер облегчённой копии видео, который адаптер может
  /// отправить; null — без ограничения (например, есть загрузка файлов).
  final int? maxVideoBytes;

  /// API позволяет задать частоту кадров, с которой модель смотрит видео.
  final bool videoFpsConfigurable;

  /// API позволяет задать уровень «размышления» модели.
  final bool thinkingConfigurable;

  /// Ответ идёт потоком: первые данные приходят, как только модель начала
  /// отвечать, а не после всей генерации. Только тогда пайплайн применяет
  /// предел ожидания начала ответа (spec 7.7).
  final bool streamsResponse;
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
    this.videoFps = 2,
    this.thinkingLevel,
    this.retryNote,
    this.previousResponse,
  });

  final String danceId;
  final String systemPrompt;
  final String userPrompt;
  final SubmissionMode mode;
  final PreparedMaterial material;

  /// Схема отчёта. Строгий структурированный вывод на стороне провайдера
  /// не включается (spec 7.5) — проверяет приложение.
  final Map<String, dynamic> reportSchema;

  /// Частота, с которой модель смотрит видео (если API это позволяет).
  final double videoFps;

  /// Уровень «размышления»: low / medium / high; null — по умолчанию модели.
  final String? thinkingLevel;

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
        videoFps: videoFps,
        thinkingLevel: thinkingLevel,
        retryNote: note,
        previousResponse: previous,
      );
}

/// Отправка (с долей загруженного, если её можно измерить), обработка
/// файла у провайдера, ожидание ответа.
enum AiPhase { sending, processing, waiting }

class AiProgress {
  const AiProgress(this.phase, [this.fraction, this.receivedBytes]);
  final AiPhase phase;
  final double? fraction;

  /// Сколько байт ответа уже получено (потоковая отдача) — живой прогресс.
  final int? receivedBytes;
}

enum AiErrorKind {
  invalidKey,
  rateLimit,
  network,
  tooLarge,
  server,
  notConfigured,

  /// Неизвестная модель или модель не принимает изображения/видео.
  modelUnavailable,

  /// На счёте провайдера нет средств.
  insufficientFunds,

  /// Запрос отклонён фильтрами провайдера.
  blocked,

  /// Сервер перегружен или временно недоступен (503 UNAVAILABLE, «high
  /// demand», overloaded, 500/502/504) — можно повторить или взять запасную
  /// модель.
  overloaded,

  /// Сервер не начал отвечать: закрыл соединение после полной отправки, не
  /// прислав заголовков, или истёк предел ожидания начала ответа. Как
  /// перегрузка — следующая модель цепочки.
  noResponse,
}

/// Откуда пришла ошибка: HTTP-статусом или событием внутри потока SSE.
enum AiErrorSource { http, sse }

/// Сведения об HTTP-обмене для «Для разработчика» (spec 7.8): когда пришли
/// заголовки и первый байт тела (от начала запроса), статус, источник ошибки.
class HttpDiag {
  const HttpDiag(
      {this.status, this.headersTime, this.firstByteTime, this.errorSource});

  final int? status;
  final Duration? headersTime;
  final Duration? firstByteTime;
  final AiErrorSource? errorSource;

  HttpDiag withSource(AiErrorSource s) => HttpDiag(
      status: status,
      headersTime: headersTime,
      firstByteTime: firstByteTime,
      errorSource: s);
}

/// Ошибка API. Текст никогда не содержит ключа.
class AiException implements Exception {
  const AiException(this.kind,
      [this.detail, this.retryAfter, this.freeTier = false])
      : notes = const [],
        sentBytes = null,
        diag = null;

  const AiException._full(this.kind, this.detail, this.retryAfter,
      this.freeTier, this.notes, this.sentBytes, this.diag);

  final AiErrorKind kind;

  /// Технические подробности для «Для разработчика» (без ключа).
  final String? detail;

  /// Сколько подождать перед повтором (Retry-After), если сервер сказал.
  final Duration? retryAfter;

  /// Бесплатная модель с дневным лимитом — подсказка в тексте ошибки.
  final bool freeTier;

  /// Заметки адаптера до ошибки (например, «схема ответа не принята»)
  /// для «Для разработчика». Без ключа.
  final List<String> notes;

  /// Сколько байт ушло в запросе, после которого пришла ошибка.
  final int? sentBytes;

  /// Сведения об HTTP-обмене (статус, время заголовков, источник ошибки).
  final HttpDiag? diag;

  /// Та же ошибка с заметками адаптера и сведениями о запросе.
  AiException withInfo(
          {List<String>? notes, String? detail, int? sentBytes, HttpDiag? diag}) =>
      AiException._full(
          kind,
          detail ?? this.detail,
          retryAfter,
          freeTier,
          notes == null ? this.notes : List.unmodifiable(notes),
          sentBytes ?? this.sentBytes,
          diag ?? this.diag);

  /// Та же ошибка с заметками адаптера.
  AiException withNotes(List<String> notes) => withInfo(notes: notes);

  @override
  String toString() => 'AiException($kind${detail == null ? '' : ': $detail'})';
}

class AiUsage {
  const AiUsage({this.inputTokens, this.outputTokens, this.thinkingTokens});

  final int? inputTokens;
  final int? outputTokens;

  /// «Размышление» модели (входит в выходные токены у большинства API).
  final int? thinkingTokens;

  Map<String, Object?> toJson() => {
        'input_tokens': inputTokens,
        'output_tokens': outputTokens,
        'thinking_tokens': thinkingTokens,
      };
}

/// Ответ модели и сведения для «Для разработчика».
class AiResponse {
  const AiResponse({
    required this.text,
    this.usage,
    this.finishReason,
    this.sentBytes,
    this.notes = const [],
    this.diag,
  });

  /// Текст ответа (JSON уже вырезан из обёртки, если она была).
  final String text;
  final AiUsage? usage;
  final String? finishReason;

  /// Размер тела запроса (или загруженного файла), байт.
  final int? sentBytes;

  /// Что адаптер сделал сам: повтор без JSON-режима, загрузка файла и т. п.
  final List<String> notes;

  /// Сведения об HTTP-обмене (если адаптер работает по HTTP).
  final HttpDiag? diag;
}

/// Что удалось узнать о модели (spec 7.2, подсказка в настройках).
class ModelLookup {
  const ModelLookup({required this.found, this.inputModalities});

  final bool found;

  /// null — API не сообщает, что принимает модель.
  final List<String>? inputModalities;
}

/// Адаптер провайдера ИИ. Интерфейс приложения не знает, какой работает.
abstract interface class AiProvider {
  /// Короткое имя для экрана анализа.
  String get displayName;

  /// Модель, как её ввёл пользователь (для «Для разработчика»).
  String get model;

  AiCapabilities get capabilities;

  /// Бросает [AiException] при ошибках API и [AnalysisCancelled] при отмене.
  Future<AiResponse> analyze(
    AiRequest request, {
    required void Function(AiProgress) onProgress,
    required CancelToken cancel,
  });

  /// null — узнать не удалось (нет сети, API не умеет).
  Future<ModelLookup?> lookupModel(CancelToken cancel);
}
