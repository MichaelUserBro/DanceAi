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
      );

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
