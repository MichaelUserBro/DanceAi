import 'package:material_ui/material_ui.dart';

import '../analysis/adapter_registry.dart';
import '../analysis/ai_provider.dart';
import '../analysis/analysis_failure.dart';
import '../analysis/analysis_pipeline.dart';
import '../analysis/providers/http_transport.dart';
import '../analysis/stub_ai_provider.dart';
import '../analysis/temp_storage.dart';
import '../analysis/video_preparer.dart';
import '../data/app_data.dart';
import '../platform/video_picker.dart';
import '../settings/settings_store.dart';

/// Что показывается в «Для разработчика»: только в памяти, без ключа.
class DevState extends ChangeNotifier {
  AnalysisTrace? _lastTrace;
  AnalysisTrace? get lastTrace => _lastTrace;

  void record(AnalysisTrace trace) {
    _lastTrace = trace;
    notifyListeners();
  }
}

/// Общие сервисы приложения.
class AppServices {
  AppServices({
    required this.data,
    required this.settings,
    required this.preparer,
    required this.tempStorage,
    required this.dev,
    required this.videoPicker,
    HttpTransport? transport,
  }) : transport = transport ?? IoHttpTransport();

  final AppData data;
  final SettingsStore settings;
  final VideoPreparer preparer;
  final TempStorage tempStorage;
  final DevState dev;
  final VideoPicker videoPicker;
  final HttpTransport transport;

  /// Адаптер выбранного провайдера; в «Демо-режиме» — заглушка (spec 7.8).
  /// Не настроено — [AnalysisFailure] `notConfigured`.
  Future<AiProvider> createProvider() async {
    if (settings.demoMode) {
      return StubAiProvider(
          catalog: data.criteria, scenario: settings.stubScenario);
    }
    final p = settings.provider;
    if (p == null || !settings.isConfigured) {
      throw const AnalysisFailure(FailureKind.notConfigured);
    }
    final key = await settings.readKey(p.id);
    if (key == null || key.isEmpty) {
      throw const AnalysisFailure(FailureKind.notConfigured);
    }
    return AdapterRegistry.create(
      provider: p,
      model: settings.modelFor(p.id),
      apiKey: key,
      baseUrl: settings.baseUrlFor(p),
      transport: transport,
    );
  }

  Future<AnalysisPipeline> createPipeline() async => AnalysisPipeline(
        data: data,
        preparer: preparer,
        provider: await createProvider(),
        tempStorage: tempStorage,
        demo: settings.demoMode,
      );
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.services;

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      oldWidget.services != services;
}
