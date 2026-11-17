import '../data/providers_catalog.dart';
import 'ai_provider.dart';
import 'providers/anthropic_provider.dart';
import 'providers/google_provider.dart';
import 'providers/http_transport.dart';
import 'providers/openai_compatible_provider.dart';
import 'providers/openai_provider.dart';

/// Адаптеры по типу API (spec 7.2, 7.3). Это единственное место, где что-то
/// зависит от типа API, — и оно описывает адаптер, а не провайдера.
abstract final class AdapterRegistry {
  static AiCapabilities capabilitiesFor(ApiType type) => switch (type) {
        ApiType.google => GoogleProvider.capabilitiesStatic,
        ApiType.openaiCompatible => OpenAiCompatibleProvider.capabilitiesStatic,
        ApiType.anthropic => AnthropicProvider.capabilitiesStatic,
        ApiType.openai => OpenAiProvider.capabilitiesStatic,
      };

  /// Настоящие адаптеры подключены; заглушка — только «Демо-режим».
  static const bool realAdaptersAvailable = true;

  /// Адаптер для провайдера. [baseUrl] — адрес «Своего» или из каталога.
  static AiProvider create({
    required ProviderInfo provider,
    required String model,
    required String apiKey,
    required String baseUrl,
    required HttpTransport transport,
  }) {
    final m = model.trim();
    final url = baseUrl.trim();
    final name = provider.name;
    return switch (provider.apiType) {
      ApiType.google => GoogleProvider(
          model: m, apiKey: apiKey, baseUrl: url, transport: transport,
          displayName: name),
      ApiType.openaiCompatible => OpenAiCompatibleProvider(
          model: m, apiKey: apiKey, baseUrl: url, transport: transport,
          displayName: name),
      ApiType.anthropic => AnthropicProvider(
          model: m, apiKey: apiKey, baseUrl: url, transport: transport,
          displayName: name),
      ApiType.openai => OpenAiProvider(
          model: m, apiKey: apiKey, baseUrl: url, transport: transport,
          displayName: name),
    };
  }
}
