import '../settings/api_key_check.dart';
import 'ai_provider.dart';
import 'analysis_pipeline.dart' show analysisTimeLimitRu;
import 'quota_time.dart';
import 'video_preparer.dart';

/// Что пользователь может сделать на экране ошибки (spec 8б.6).
enum FailureAction { retry, chooseOtherVideo, openSettings, sendFrames }

enum FailureKind {
  noAudio,
  unreadableVideo,
  invalidKey,
  rateLimit,
  network,
  tooLarge,
  server,
  notConfigured,
  invalidResponse,
  internal,

  /// Неизвестная модель или модель не принимает этот материал.
  modelUnavailable,
  insufficientFunds,
  blocked,

  /// Облегчённая копия больше, чем принимает адаптер (или сервер ответил
  /// «слишком большой запрос») в режиме видео — можно отправить кадрами.
  videoTooLarge,

  /// Облегчённую копию сделать не удалось — можно отправить кадрами.
  videoEncodeFailed,

  /// Анализ не уложился в потолок времени (spec 7.7).
  timeLimit,

  /// Сервер ИИ перегружен: повторы и запасные модели не помогли (spec 7.7).
  overloaded,

  /// Ключ с недопустимыми символами — запрос не уходит (spec 7.2).
  keyFormat,

  /// Провайдер не работает из страны пользователя — нужен VPN.
  regionBlocked,
}

/// Понятная ошибка анализа: русский текст и действия. Ключ в текст не попадает.
class AnalysisFailure implements Exception {
  const AnalysisFailure(this.kind,
      {this.details = const [],
      this.retryAfter,
      this.freeTier = false,
      this.videoMode = false,
      this.hintRu,
      this.framesFallback = false,
      this.providerName});

  factory AnalysisFailure.fromPrepare(PrepareException e) =>
      AnalysisFailure(switch (e.kind) {
        PrepareErrorKind.noAudio => FailureKind.noAudio,
        PrepareErrorKind.unreadable => FailureKind.unreadableVideo,
        PrepareErrorKind.encodeFailed => FailureKind.videoEncodeFailed,
      });

  /// [videoMode] — материал отправлялся видео целиком: «слишком большой
  /// запрос» тогда решается отправкой кадрами.
  factory AnalysisFailure.fromAi(AiException e,
          {bool videoMode = false, String? providerName, String? hintRu}) =>
      AnalysisFailure(
        switch (e.kind) {
          AiErrorKind.invalidKey => FailureKind.invalidKey,
          AiErrorKind.rateLimit => FailureKind.rateLimit,
          AiErrorKind.network => FailureKind.network,
          AiErrorKind.tooLarge =>
            videoMode ? FailureKind.videoTooLarge : FailureKind.tooLarge,
          AiErrorKind.server => FailureKind.server,
          AiErrorKind.notConfigured => FailureKind.notConfigured,
          AiErrorKind.modelUnavailable => FailureKind.modelUnavailable,
          AiErrorKind.insufficientFunds => FailureKind.insufficientFunds,
          AiErrorKind.blocked => FailureKind.blocked,
          AiErrorKind.overloaded ||
          AiErrorKind.noResponse =>
            FailureKind.overloaded,
          AiErrorKind.keyFormat => FailureKind.keyFormat,
          AiErrorKind.requestFormat => FailureKind.internal,
          AiErrorKind.regionBlocked => FailureKind.regionBlocked,
        },
        details: [?e.detail],
        retryAfter: e.retryAfter,
        freeTier: e.freeTier,
        videoMode: videoMode,
        providerName: providerName,
        hintRu: hintRu,
      );

  final FailureKind kind;

  /// Лимит запросов: через сколько можно повторить (если сервер сказал).
  final Duration? retryAfter;

  /// Бесплатная модель с дневным лимитом.
  final bool freeTier;

  /// Материал отправлялся видео целиком (можно предложить кадры).
  final bool videoMode;

  /// Подсказка провайдера о сбросе квоты (`overload_hint_ru`): только если
  /// среди попыток был 429 дневной квоты.
  final String? hintRu;

  /// Имя провайдера (для «Google не работает из вашей страны»).
  final String? providerName;

  /// Перегрузка в режиме видео: есть запасные модели, принимающие только
  /// кадры, — можно «Отправить кадрами».
  final bool framesFallback;

  /// Та же ошибка с другими подробностями.
  AnalysisFailure withDetails(List<String> details) => AnalysisFailure(kind,
      details: details,
      retryAfter: retryAfter,
      freeTier: freeTier,
      videoMode: videoMode,
      hintRu: hintRu,
      framesFallback: framesFallback,
      providerName: providerName);

  /// Технические подробности для раздела «Для разработчика».
  final List<String> details;

  String get title => switch (kind) {
        FailureKind.noAudio => 'В видео нет звука',
        FailureKind.unreadableVideo => 'Не удалось открыть видео',
        FailureKind.invalidKey => 'Неверный ключ API',
        FailureKind.rateLimit => 'Лимит запросов',
        FailureKind.network => 'Нет связи с ИИ',
        FailureKind.tooLarge => 'Видео слишком большое',
        FailureKind.server => 'Ошибка на стороне ИИ',
        FailureKind.notConfigured => 'ИИ не настроен',
        FailureKind.invalidResponse => 'ИИ ответил не по формату',
        FailureKind.internal => 'Что-то пошло не так',
        FailureKind.modelUnavailable => 'Модель недоступна',
        FailureKind.insufficientFunds => 'Нет средств на счёте',
        FailureKind.blocked => 'Запрос отклонён провайдером',
        FailureKind.videoTooLarge => 'Видео слишком большое для модели',
        FailureKind.videoEncodeFailed => 'Не удалось подготовить видео',
        FailureKind.timeLimit => 'ИИ отвечает слишком долго',
        FailureKind.overloaded => 'Сервер ИИ перегружен',
        FailureKind.keyFormat => 'В ключе API недопустимые символы',
        FailureKind.regionBlocked =>
          '${providerName ?? 'Провайдер ИИ'} не работает из вашей страны',
      };

  String get message => switch (kind) {
        FailureKind.noAudio =>
          'В видео нет звука. Для оценки нужна музыка. Выберите видео со звуком.',
        FailureKind.unreadableVideo =>
          'Не удалось открыть видео, выберите его заново. Если не '
              'поможет — файл повреждён или это не видео.',
        FailureKind.invalidKey =>
          'Провайдер не принял ключ API. Проверьте ключ в настройках.',
        FailureKind.rateLimit => [
            'Превышен лимит запросов провайдера.',
            if (hintRu != null)
              'Дневной лимит бесплатного тарифа исчерпан: '
                  '${fillQuotaHint(hintRu!)}.'
            else if (retryAfter != null)
              'Повторить можно через ${_wait(retryAfter!)}.'
            else
              'Подождите немного и повторите или выберите другую модель.',
            if (freeTier && hintRu == null)
              'У бесплатных моделей есть и дневной лимит запросов — если он '
                  'исчерпан, повторить можно только завтра.',
          ].join(' '),
        FailureKind.network =>
          'Не удалось связаться с провайдером ИИ. Проверьте интернет '
              '(и VPN, если он нужен для этого провайдера).',
        FailureKind.tooLarge =>
          'Модель не принимает такой объём. Выберите видео короче или '
              'выключите «Модель принимает видео со звуком».',
        FailureKind.server =>
          'Провайдер ИИ вернул ошибку. Повторите попытку чуть позже.',
        FailureKind.notConfigured =>
          'Выберите провайдера, модель и введите ключ API в настройках.',
        FailureKind.invalidResponse =>
          'Ответ ИИ не прошёл проверку даже после повторного запроса. '
              'Повторите анализ или выберите другую модель.',
        FailureKind.internal =>
          'Произошла внутренняя ошибка. Повторите попытку.',
        FailureKind.modelUnavailable =>
          'Провайдер не нашёл модель или модель не принимает изображения '
              '(видео). Проверьте название модели в настройках или выберите '
              'другую.',
        FailureKind.insufficientFunds => videoMode
            ? 'Провайдер не принял видео: на счёте недостаточно средств. '
                'Для видео часть провайдеров требует положительный баланс даже '
                'на бесплатных моделях. Можно отправить то же видео кадрами.'
            : 'На счёте провайдера недостаточно средств. Пополните баланс или '
                'выберите бесплатную модель.',
        FailureKind.blocked =>
          'Провайдер отклонил запрос своими фильтрами. Попробуйте другую '
              'модель или другое видео.',
        FailureKind.videoTooLarge =>
          'Модель не принимает видео такого размера. Можно отправить то же '
              'видео кадрами — выбирать заново не нужно.',
        FailureKind.videoEncodeFailed =>
          'Не удалось подготовить видео для отправки целиком. Можно '
              'отправить его кадрами — выбирать заново не нужно.',
        FailureKind.keyFormat =>
          '$apiKeyBadCharsRu Откройте настройки и вставьте ключ заново.',
        FailureKind.regionBlocked =>
          'Провайдер не принимает запросы из вашей страны. Включите VPN со '
              'страной, где сервис доступен, и проверьте, что VPN действует '
              'для DanceAI: при раздельном туннелировании добавьте DanceAI в '
              'список приложений, которые идут через VPN.',
        FailureKind.timeLimit =>
          'ИИ не успел подготовить отчёт за $analysisTimeLimitRu. '
              'Попробуйте ещё раз — провайдер мог быть перегружен — или '
              'выберите в настройках более быструю модель.',
        FailureKind.overloaded => [
            if (hintRu == null)
              'На бесплатном тарифе такое бывает. Попробуйте через несколько '
                  'минут.'
            else
              'На бесплатном тарифе такое бывает. Попробуйте через несколько '
                  'минут; дневной лимит одной из моделей исчерпан '
                  '(${fillQuotaHint(hintRu!)}).',
            if (framesFallback)
              'Можно отправить то же видео кадрами — для кадров есть '
                  'запасные модели.',
          ].join(' '),
      };

  /// «Попробовать ещё раз» после потолка времени, иначе «Повторить».
  String get retryLabel =>
      kind == FailureKind.timeLimit || kind == FailureKind.overloaded
          ? 'Попробовать ещё раз'
          : 'Повторить';

  static String _wait(Duration d) {
    final s = d.inSeconds;
    if (s < 60) return '${s < 1 ? 1 : s} с';
    final m = (s / 60).ceil();
    if (m < 120) return '$m мин';
    return '${(m / 60).ceil()} ч';
  }

  List<FailureAction> get actions => switch (kind) {
        FailureKind.noAudio ||
        FailureKind.unreadableVideo =>
          const [FailureAction.chooseOtherVideo],
        FailureKind.invalidKey ||
        FailureKind.keyFormat ||
        FailureKind.notConfigured =>
          const [FailureAction.openSettings, FailureAction.retry],
        FailureKind.regionBlocked => const [FailureAction.retry],
        FailureKind.tooLarge => const [
            FailureAction.chooseOtherVideo,
            FailureAction.openSettings,
          ],
        FailureKind.rateLimit || FailureKind.invalidResponse => const [
            FailureAction.retry,
            FailureAction.openSettings,
            FailureAction.chooseOtherVideo,
          ],
        FailureKind.videoTooLarge || FailureKind.videoEncodeFailed => const [
            FailureAction.sendFrames,
            FailureAction.chooseOtherVideo,
          ],
        FailureKind.timeLimit => const [
            FailureAction.retry,
            FailureAction.openSettings,
          ],
        FailureKind.overloaded when framesFallback => const [
            FailureAction.sendFrames,
            FailureAction.retry,
          ],
        FailureKind.overloaded => const [
            FailureAction.retry,
            FailureAction.openSettings,
          ],
        FailureKind.insufficientFunds when videoMode => const [
            FailureAction.sendFrames,
            FailureAction.openSettings,
          ],
        FailureKind.modelUnavailable || FailureKind.insufficientFunds => const [
            FailureAction.openSettings,
            FailureAction.retry,
          ],
        _ => const [FailureAction.retry, FailureAction.chooseOtherVideo],
      };

  @override
  String toString() => 'AnalysisFailure($kind)';
}
