import 'package:material_ui/material_ui.dart';

import '../analysis/analysis_pipeline.dart';
import '../analysis/stub_ai_provider.dart';
import '../analysis/temp_storage.dart';
import '../analysis/video_preparer.dart';
import '../data/app_data.dart';
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
  });

  final AppData data;
  final SettingsStore settings;
  final VideoPreparer preparer;
  final TempStorage tempStorage;
  final DevState dev;

  /// Пока настоящих адаптеров нет, анализ всегда идёт через заглушку (spec 7.8).
  AnalysisPipeline createPipeline() => AnalysisPipeline(
        data: data,
        preparer: preparer,
        provider: StubAiProvider(
          catalog: data.criteria,
          scenario: settings.stubScenario,
        ),
        tempStorage: tempStorage,
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
