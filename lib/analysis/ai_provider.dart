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
    this.shared,
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

  /// Материал, загруженный один раз на весь анализ ([AiSharedMaterial]):
  /// его используют все попытки и модели цепочки. null — каждая попытка
  /// отправляет материал сама.
  final Object? shared;

  /// Тот же запрос с общим материалом.
  AiRequest withShared(Object? handle) => AiRequest(
        danceId: danceId,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        mode: mode,
        material: material,
        reportSchema: reportSchema,
        videoFps: videoFps,
        thinkingLevel: thinkingLevel,
        retryNote: retryNote,
        previousResponse: previousResponse,
        shared: handle,
      );

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
        shared: shared,
      );
}

/// Отправка (с долей загруженного, если её можно измерить), обработка
/// файла у провайдера, ожидание ответа.
enum AiPhase { sending, processing, waiting }

class AiProgress {
  const AiProgress(this.phase,
      [this.fraction, this.receivedBytes, this.sentBytes]);
  final AiPhase phase;
  final double? fraction;

  /// Сколько байт ответа уже получено (потоковая отдача) — живой прогресс.
  final int? receivedBytes;

  /// Сколько байт запроса фактически отправлено (для прерванной попытки).
  final int? sentBytes;
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

  /// Ключ содержит символы, недопустимые в заголовке HTTP (невидимые,
  /// перенос строки, кириллица) — запрос не уходит.
  keyFormat,

  /// Запрос не собрался (недопустимое значение заголовка и т. п.) — не сеть.
  requestFormat,

  /// Провайдер не работает из страны пользователя (Google: 400
  /// FAILED_PRECONDITION «User location is not supported»).
  regionBlocked,
}

/// Какая квота исчерпана (429): поминутная — можно подождать `retryDelay`,
/// дневная — только следующая модель.
enum QuotaScope { minute, day }

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
        diag = null,
        quota = null,
        quotaId = null,
        fullDetail = null;

  const AiException.full(
    this.kind, {
    this.detail,
    this.retryAfter,
    this.freeTier = false,
    this.notes = const [],
    this.sentBytes,
    this.diag,
    this.quota,
    this.quotaId,
    this.fullDetail,
  });

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

  /// 429: какая квота исчерпана (если провайдер сообщил) и её id.
  final QuotaScope? quota;
  final String? quotaId;

  /// Полный текст ошибки провайдера (без ключа) — для JSON; [detail]
  /// короче, для экрана.
  final String? fullDetail;

  /// Та же ошибка с заметками адаптера и сведениями о запросе.
  AiException withInfo(
          {List<String>? notes,
          String? detail,
          String? fullDetail,
          int? sentBytes,
          HttpDiag? diag}) =>
      AiException.full(
        kind,
        detail: detail ?? this.detail,
        retryAfter: retryAfter,
        freeTier: freeTier,
        notes: notes == null ? this.notes : List.unmodifiable(notes),
        sentBytes: sentBytes ?? this.sentBytes,
        diag: diag ?? this.diag,
        quota: quota,
        quotaId: quotaId,
        fullDetail: fullDetail ?? this.fullDetail,
      );

  /// Та же ошибка со сведениями о квоте (разбор адаптера).
  AiException withQuota(QuotaScope? scope,
          {String? quotaId, Duration? retryAfter}) =>
      AiException.full(
        kind,
        detail: detail,
        retryAfter: retryAfter ?? this.retryAfter,
        freeTier: freeTier,
        notes: notes,
        sentBytes: sentBytes,
        diag: diag,
        quota: scope,
        quotaId: quotaId ?? this.quotaId,
        fullDetail: fullDetail,
      );

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

/// Итог предварительной проверки (spec 7.7): запрос, статус, время.
class PrecheckResult {
  const PrecheckResult(
      {required this.request, this.status, required this.time, this.error});

  /// Что проверялось (`POST models/…:countTokens`), без ключа.
  final String request;
  final int? status;
  final Duration time;

  /// null — проверка прошла (или её исход не мешает анализу).
  final AiException? error;

  Map<String, Object?> toJson() => {
        'request': request,
        'http_status': status,
        'time_ms': time.inMilliseconds,
        'error': error == null
            ? null
            : '${error!.kind.name}${error!.detail == null ? '' : ': ${error!.detail}'}',
      };
}

/// Адаптер умеет дешёвую проверку до подготовки видео: ключ, модель,
/// доступность из страны пользователя. Квоту генерации не тратит.
abstract interface class AiPrecheck {
  Future<PrecheckResult> precheck(CancelToken cancel);
}

/// Как ушёл материал: один раз через хранилище файлов провайдера
/// (`file_api`), в каждой попытке (`inline`), или в каждой попытке после
/// сбоя загрузки (`inline_fallback`).
enum UploadMode { fileApi, inline, inlineFallback }

/// Материал, загруженный один раз на анализ (или решение его не загружать).
class SharedMaterial {
  const SharedMaterial({
    required this.mode,
    this.handle,
    this.bytes,
    this.uploadTime,
    this.activeWait,
    this.notes = const [],
  });

  final UploadMode mode;

  /// Передаётся в [AiRequest.shared]; null — материал не загружен.
  final Object? handle;
  final int? bytes;
  final Duration? uploadTime;

  /// Ожидание готовности файла у провайдера (Google: состояние ACTIVE).
  final Duration? activeWait;
  final List<String> notes;

  Map<String, Object?> toJson() => {
        'upload_mode': switch (mode) {
          UploadMode.fileApi => 'file_api',
          UploadMode.inline => 'inline',
          UploadMode.inlineFallback => 'inline_fallback',
        },
        'bytes': bytes,
        'upload_ms': uploadTime?.inMilliseconds,
        'active_wait_ms': activeWait?.inMilliseconds,
        'notes': notes,
      };
}

/// Адаптер загружает материал один раз на весь анализ (цепочку моделей
/// того же провайдера) и удаляет его в конце в любом исходе.
abstract interface class AiSharedMaterial {
  /// null — общий материал не нужен (например, кадры).
  Future<SharedMaterial?> prepareShared(AiRequest request,
      {required void Function(AiProgress) onProgress,
      required CancelToken cancel});

  Future<void> releaseShared(SharedMaterial material, List<String> notes);
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
