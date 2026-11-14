import '../data/providers_catalog.dart';
import 'ai_provider.dart';

/// Возможности адаптеров по типу API (spec 7.2, 7.3). Это единственное место,
/// где что-то зависит от типа API, — и оно описывает адаптер, а не провайдера.
/// Значения предварительные: уточнятся при подключении адаптеров (шаг 5).
abstract final class AdapterRegistry {
  static AiCapabilities capabilitiesFor(ApiType type) => switch (type) {
        // Передача видео целиком в запросе поддерживается API.
        ApiType.google || ApiType.openaiCompatible =>
          const AiCapabilities(supportsVideo: true),
        // API принимают изображения, но не видео.
        ApiType.anthropic || ApiType.openai =>
          const AiCapabilities(supportsVideo: false),
      };

  /// Настоящие адаптеры пока не подключены — анализ идёт через заглушку.
  static const bool realAdaptersAvailable = false;
}
