import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analysis/adapter_registry.dart';
import '../analysis/stub_ai_provider.dart';
import '../data/providers_catalog.dart';
import 'api_key_check.dart';
import 'secure_key_store.dart';

/// Обычные (не секретные) настройки.
abstract interface class PrefsStore {
  Future<String?> getString(String key);
  Future<bool?> getBool(String key);
  Future<void> setString(String key, String value);
  Future<void> setBool(String key, bool value);
}

class SharedPrefsStore implements PrefsStore {
  SharedPrefsStore([SharedPreferencesAsync? prefs])
      : _prefs = prefs ?? SharedPreferencesAsync();
  final SharedPreferencesAsync _prefs;

  @override
  Future<String?> getString(String key) => _prefs.getString(key);
  @override
  Future<bool?> getBool(String key) => _prefs.getBool(key);
  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);
  @override
  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);
}

/// Для тестов.
class MemoryPrefsStore implements PrefsStore {
  final values = <String, Object>{};

  @override
  Future<String?> getString(String key) async => values[key] as String?;
  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;
  @override
  Future<void> setString(String key, String value) async => values[key] = value;
  @override
  Future<void> setBool(String key, bool value) async => values[key] = value;
}

/// Настройки ИИ. Обычные значения — в shared_preferences,
/// ключ — только в [KeyStore]. Сам ключ здесь не хранится:
/// известно лишь, задан ли он.
class SettingsStore extends ChangeNotifier {
  SettingsStore({
    required this.catalog,
    required this._prefs,
    required this.keys,
  });

  final ProvidersCatalog catalog;
  final PrefsStore _prefs;
  final KeyStore keys;

  String? _providerId;
  final _models = <String, String>{};
  final _videoMode = <String, bool>{};
  final _hasKey = <String, bool>{};
  String _customBaseUrl = '';
  StubScenario _scenario = StubScenario.normal;
  bool _demoMode = false;
  double _videoFps = 2;
  String? _thinkingLevel;
  final _maxFrames = <String, int>{};
  final _useFallback = <String, bool>{};

  static const _kProvider = 'provider_id';
  static const _kCustomUrl = 'custom_base_url';
  static const _kScenario = 'stub_scenario';
  static const _kDemo = 'demo_mode';
  static const _kVideoFps = 'video_fps';
  static const _kThinking = 'thinking_level';
  static String _kMaxFrames(String id) => 'max_frames.$id';
  static String _kFallback(String id) => 'use_fallback.$id';

  /// Уровни размышления в «Для разработчика» (null — по умолчанию модели).
  static const thinkingLevels = ['low', 'medium', 'high'];

  /// Допустимый «Максимум кадров».
  static const maxFramesRange = (min: 1, max: 600);

  /// Частоты для видеорежима в «Для разработчика».
  static const videoFpsChoices = [1.0, 2.0, 4.0];
  static String _kModel(String id) => 'model.$id';
  static String _kVideo(String id) => 'video_mode.$id';

  Future<void> load() async {
    _providerId = await _prefs.getString(_kProvider);
    _customBaseUrl = await _prefs.getString(_kCustomUrl) ?? '';
    _scenario = StubScenario.fromId(await _prefs.getString(_kScenario));
    _demoMode = await _prefs.getBool(_kDemo) ?? false;
    final fps = double.tryParse(await _prefs.getString(_kVideoFps) ?? '');
    _videoFps = videoFpsChoices.contains(fps) ? fps! : 2;
    final t = await _prefs.getString(_kThinking);
    _thinkingLevel = thinkingLevels.contains(t) ? t : null;
    for (final p in catalog.all) {
      final model = await _prefs.getString(_kModel(p.id));
      if (model != null) _models[p.id] = model;
      // Не выбирал сам — значение провайдера (`video_default`).
      _videoMode[p.id] = await _prefs.getBool(_kVideo(p.id)) ?? p.videoDefault;
      final mf = int.tryParse(await _prefs.getString(_kMaxFrames(p.id)) ?? '');
      if (mf != null) _maxFrames[p.id] = mf;
      _useFallback[p.id] = await _prefs.getBool(_kFallback(p.id)) ?? true;
      final key = await keys.read(p.id);
      _hasKey[p.id] = key != null && key.isNotEmpty;
    }
    if (catalog.byId(_providerId) == null) _providerId = null;
    notifyListeners();
  }

  ProviderInfo? get provider => catalog.byId(_providerId);

  String modelFor(String providerId) => _models[providerId] ?? '';
  bool hasKeyFor(String providerId) => _hasKey[providerId] ?? false;
  String get customBaseUrl => _customBaseUrl;
  StubScenario get stubScenario => _scenario;

  /// «Демо-режим (без ИИ)»: анализ через заглушку, без ключа и лимитов.
  bool get demoMode => _demoMode;

  /// Частота, с которой модель смотрит видео (где API это позволяет).
  double get videoFps => _videoFps;

  /// Уровень размышления (где API позволяет); null — по умолчанию модели.
  String? get thinkingLevel => _thinkingLevel;

  /// «Максимум кадров» провайдера; null — по умолчанию адаптера.
  int? maxFramesFor(String providerId) => _maxFrames[providerId];

  /// «Использовать запасные модели при перегрузке» (по умолчанию включено).
  bool useFallbackFor(String providerId) => _useFallback[providerId] ?? true;

  /// Адаптер выбранного провайдера умеет передавать видео.
  bool canSendVideo(ProviderInfo p) =>
      AdapterRegistry.capabilitiesFor(p.apiType).supportsVideo;

  /// Переключатель «Модель принимает видео со звуком» (с учётом адаптера).
  bool videoModeFor(ProviderInfo p) =>
      canSendVideo(p) && (_videoMode[p.id] ?? false);

  bool get wantVideo => provider != null && videoModeFor(provider!);

  /// Выбраны провайдер и модель, задан ключ (и адрес — для «Своего»).
  bool get isConfigured {
    final p = provider;
    if (p == null) return false;
    if (modelFor(p.id).trim().isEmpty || !hasKeyFor(p.id)) return false;
    if (p.isCustom && _customBaseUrl.trim().isEmpty) return false;
    return true;
  }

  Future<void> selectProvider(String id) async {
    _providerId = id;
    notifyListeners();
    await _prefs.setString(_kProvider, id);
  }

  Future<void> setModel(String providerId, String model) async {
    _models[providerId] = model;
    notifyListeners();
    await _prefs.setString(_kModel(providerId), model);
  }

  Future<void> setCustomBaseUrl(String url) async {
    _customBaseUrl = url;
    notifyListeners();
    await _prefs.setString(_kCustomUrl, url);
  }

  Future<void> setVideoMode(String providerId, bool value) async {
    _videoMode[providerId] = value;
    notifyListeners();
    await _prefs.setBool(_kVideo(providerId), value);
  }

  Future<void> setStubScenario(StubScenario s) async {
    _scenario = s;
    notifyListeners();
    await _prefs.setString(_kScenario, s.id);
  }

  Future<void> setDemoMode(bool value) async {
    _demoMode = value;
    notifyListeners();
    await _prefs.setBool(_kDemo, value);
  }

  Future<void> setVideoFps(double fps) async {
    if (!videoFpsChoices.contains(fps)) return;
    _videoFps = fps;
    notifyListeners();
    await _prefs.setString(_kVideoFps, '$fps');
  }

  Future<void> setThinkingLevel(String? level) async {
    _thinkingLevel = thinkingLevels.contains(level) ? level : null;
    notifyListeners();
    await _prefs.setString(_kThinking, _thinkingLevel ?? '');
  }

  Future<void> setUseFallback(String providerId, bool value) async {
    _useFallback[providerId] = value;
    notifyListeners();
    await _prefs.setBool(_kFallback(providerId), value);
  }

  /// Пусто или вне диапазона — по умолчанию адаптера.
  Future<void> setMaxFrames(String providerId, int? value) async {
    final r = maxFramesRange;
    if (value == null || value < r.min || value > r.max) {
      _maxFrames.remove(providerId);
    } else {
      _maxFrames[providerId] = value;
    }
    notifyListeners();
    await _prefs.setString(
        _kMaxFrames(providerId), _maxFrames[providerId]?.toString() ?? '');
  }

  /// Адрес API выбранного провайдера («Свой» — введённый пользователем).
  String baseUrlFor(ProviderInfo p) => p.isCustom ? _customBaseUrl : p.baseUrl;

  Future<String?> readKey(String providerId) => keys.read(providerId);

  /// Сохраняет ключ после очистки ([checkApiKey]). Ключ с недопустимыми
  /// символами не сохраняется — возвращается текст для пользователя.
  Future<String?> saveKey(String providerId, String key) async {
    final check = checkApiKey(key);
    if (!check.ok) return apiKeyBadCharsRu;
    final clean = check.key;
    if (clean.isEmpty) {
      await keys.delete(providerId);
    } else {
      await keys.write(providerId, clean);
    }
    _hasKey[providerId] = clean.isNotEmpty;
    notifyListeners();
    return null;
  }
}
