import 'ai_provider.dart';
import 'video_preparer.dart';

/// Что пользователь может сделать на экране ошибки (spec 8б.6).
enum FailureAction { retry, chooseOtherVideo, openSettings }

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
}

/// Понятная ошибка анализа: русский текст и действия. Ключ в текст не попадает.
class AnalysisFailure implements Exception {
  const AnalysisFailure(this.kind, {this.details = const []});

  factory AnalysisFailure.fromPrepare(PrepareException e) => AnalysisFailure(
      e.kind == PrepareErrorKind.noAudio
          ? FailureKind.noAudio
          : FailureKind.unreadableVideo);

  factory AnalysisFailure.fromAi(AiException e) => AnalysisFailure(
        switch (e.kind) {
          AiErrorKind.invalidKey => FailureKind.invalidKey,
          AiErrorKind.rateLimit => FailureKind.rateLimit,
          AiErrorKind.network => FailureKind.network,
          AiErrorKind.tooLarge => FailureKind.tooLarge,
          AiErrorKind.server => FailureKind.server,
          AiErrorKind.notConfigured => FailureKind.notConfigured,
        },
        details: [?e.detail],
      );

  final FailureKind kind;

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
      };

  String get message => switch (kind) {
        FailureKind.noAudio =>
          'В видео нет звука. Для оценки нужна музыка. Выберите видео со звуком.',
        FailureKind.unreadableVideo =>
          'Не удалось открыть видео, выберите его заново. Если не '
              'поможет — файл повреждён или это не видео.',
        FailureKind.invalidKey =>
          'Провайдер не принял ключ API. Проверьте ключ в настройках.',
        FailureKind.rateLimit =>
          'Превышен лимит запросов провайдера. Подождите немного и повторите '
              'или выберите другую модель.',
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
      };

  List<FailureAction> get actions => switch (kind) {
        FailureKind.noAudio ||
        FailureKind.unreadableVideo =>
          const [FailureAction.chooseOtherVideo],
        FailureKind.invalidKey ||
        FailureKind.notConfigured =>
          const [FailureAction.openSettings, FailureAction.retry],
        FailureKind.tooLarge => const [
            FailureAction.chooseOtherVideo,
            FailureAction.openSettings,
          ],
        FailureKind.rateLimit || FailureKind.invalidResponse => const [
            FailureAction.retry,
            FailureAction.openSettings,
            FailureAction.chooseOtherVideo,
          ],
        _ => const [FailureAction.retry, FailureAction.chooseOtherVideo],
      };

  @override
  String toString() => 'AnalysisFailure($kind)';
}
