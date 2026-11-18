// Типизированная модель assets/providers.json. Провайдеры равноправны:
// в интерфейсе — по алфавиту, без приоритетов.

enum ApiType {
  anthropic('anthropic'),
  google('google'),
  openai('openai'),
  openaiCompatible('openai_compatible');

  const ApiType(this.wire);
  final String wire;

  static ApiType fromWire(String value) =>
      values.firstWhere((t) => t.wire == value,
          orElse: () => throw FormatException('Неизвестный api_type: $value'));
}

/// Запасная модель провайдера (spec 7.7): берётся при перегрузке (503) или
/// исчерпанной квоте (429) основной. [modes] — способы подачи, которые она
/// принимает: `frames`, `video`.
class FallbackModel {
  const FallbackModel({required this.id, required this.modes});

  factory FallbackModel.fromJson(Map<String, dynamic> json) => FallbackModel(
        id: json['id'] as String,
        modes: Set.unmodifiable((json['modes'] as List).cast<String>()),
      );

  static const knownModes = {'frames', 'video'};

  final String id;
  final Set<String> modes;
}

class ProviderInfo {
  const ProviderInfo({
    required this.id,
    required this.name,
    required this.apiType,
    required this.baseUrl,
    required this.keyUrl,
    required this.keyStepsRu,
    required this.freeNoteRu,
    required this.recommendedModels,
    this.hintRu,
    this.isCustom = false,
    this.verifiedLive = true,
    this.modelHintRu,
    this.fallbackModels = const [],
    this.overloadHintRu,
    this.videoDefault = false,
    this.expectedSec = const {},
  });

  factory ProviderInfo.fromJson(Map<String, dynamic> json) => ProviderInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        apiType: ApiType.fromWire(json['api_type'] as String),
        baseUrl: json['base_url'] as String,
        keyUrl: json['key_url'] as String?,
        keyStepsRu: (json['key_steps_ru'] as List).cast<String>(),
        freeNoteRu: json['free_note_ru'] as String?,
        recommendedModels:
            (json['recommended_models'] as List? ?? const []).cast<String>(),
        verifiedLive: json['verified_live'] as bool? ?? true,
        modelHintRu: json['model_hint_ru'] as String?,
        fallbackModels: [
          for (final f in json['fallback_models'] as List? ?? const [])
            FallbackModel.fromJson(f as Map<String, dynamic>),
        ],
        overloadHintRu: json['overload_hint_ru'] as String?,
        videoDefault: json['video_default'] as bool? ?? false,
        expectedSec: _expected(json['expected_sec']),
      );

  /// `expected_sec`: {"default": {режим: с}, "models": {модель: {режим: с}}}
  /// → {модель или "*": {режим: с}}.
  static Map<String, Map<String, int>> _expected(Object? json) {
    if (json is! Map) return const {};
    Map<String, int> modes(Object? m) => {
          if (m is Map)
            for (final e in m.entries)
              if (e.value is num) '${e.key}': (e.value as num).round(),
        };
    final models = json['models'];
    return {
      if (json['default'] != null) '*': modes(json['default']),
      if (models is Map)
        for (final e in models.entries) '${e.key}': modes(e.value),
    };
  }

  factory ProviderInfo.customFromJson(Map<String, dynamic> json) =>
      ProviderInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        apiType: ApiType.fromWire(json['api_type'] as String),
        baseUrl: '',
        keyUrl: null,
        keyStepsRu: const [],
        freeNoteRu: null,
        recommendedModels: const [],
        hintRu: json['hint_ru'] as String?,
        isCustom: true,
      );

  final String id;
  final String name;
  final ApiType apiType;

  /// Для «Своего» пусто — адрес вводит пользователь.
  final String baseUrl;
  final String? keyUrl;
  final List<String> keyStepsRu;
  final String? freeNoteRu;
  final List<String> recommendedModels;
  final String? hintRu;
  final bool isCustom;

  /// Адаптер проверен на живом API. false — пометка «не проверено вживую»
  /// (поле `verified_live` в providers.json).
  final bool verifiedLive;

  /// Подсказка под полем «Модель» (`model_hint_ru`).
  final String? modelHintRu;

  /// Запасные модели при перегрузке, лучшие первыми (`fallback_models`).
  final List<FallbackModel> fallbackModels;

  /// Дополнение к ошибке «Сервер ИИ перегружен» (`overload_hint_ru`);
  /// `{{pacific_midnight_msk}}` — полночь по тихоокеанскому времени в МСК.
  final String? overloadHintRu;

  /// «Модель принимает видео со звуком» включено по умолчанию, если
  /// пользователь сам не выбирал (`video_default`).
  final bool videoDefault;

  /// Ожидаемое время ответа по модели и режиму, с (`expected_sec`; ключ
  /// `*` — для незнакомой модели).
  final Map<String, Map<String, int>> expectedSec;

  /// Ожидаемое время ответа модели в режиме `frames` / `video`; null — нет
  /// данных (пайплайн берёт своё значение по умолчанию).
  Duration? expectedTime(String model, String mode) {
    final m = model.startsWith('models/') ? model.substring(7) : model;
    final s = expectedSec[m]?[mode] ?? expectedSec['*']?[mode];
    return s == null ? null : Duration(seconds: s);
  }
}

class ProvidersCatalog {
  ProvidersCatalog({required List<ProviderInfo> providers, required this.custom})
      : providers = List.unmodifiable(
            [...providers]..sort((a, b) =>
                a.name.toLowerCase().compareTo(b.name.toLowerCase())));

  factory ProvidersCatalog.fromJson(Map<String, dynamic> json) =>
      ProvidersCatalog(
        providers: [
          for (final p in json['providers'] as List)
            ProviderInfo.fromJson(p as Map<String, dynamic>),
        ],
        custom: ProviderInfo.customFromJson(
            json['custom'] as Map<String, dynamic>),
      );

  /// По алфавиту.
  final List<ProviderInfo> providers;
  final ProviderInfo custom;

  /// Все варианты для выбора: по алфавиту, «Свой» — последним.
  List<ProviderInfo> get all => [...providers, custom];

  ProviderInfo? byId(String? id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }
}
