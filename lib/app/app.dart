import 'package:material_ui/material_ui.dart';

import '../analysis/device_video_preparer.dart';
import '../analysis/temp_storage.dart';
import '../data/app_data.dart';
import '../settings/secure_key_store.dart';
import '../settings/settings_store.dart';
import '../theme/stage_theme.dart';
import '../ui/screens/home_screen.dart';
import '../ui/widgets/stage_background.dart';
import 'app_scope.dart';
import 'licenses.dart';

class DanceAiApp extends StatefulWidget {
  const DanceAiApp({super.key, this.servicesOverride});

  /// Для тестов: готовые сервисы вместо загрузки с устройства.
  final Future<AppServices>? servicesOverride;

  @override
  State<DanceAiApp> createState() => _DanceAiAppState();
}

class _DanceAiAppState extends State<DanceAiApp> {
  late final Future<AppServices> _services =
      widget.servicesOverride ?? _bootstrap();

  static Future<AppServices> _bootstrap() async {
    registerAppLicenses();
    final data = await AppData.load();
    final temp = TempStorage();
    final settings = SettingsStore(
      catalog: data.providers,
      prefs: SharedPrefsStore(),
      keys: SecureKeyStore(),
    );
    await Future.wait([
      settings.load(),
      // Остатки прошлых анализов (если приложение закрыли посреди анализа).
      temp.cleanupStale(),
    ]);
    return AppServices(
      data: data,
      settings: settings,
      preparer: DeviceVideoPreparer(),
      tempStorage: temp,
      dev: DevState(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppServices>(
      future: _services,
      builder: (context, snap) {
        final Widget home;
        if (snap.hasError) {
          home = const _Fatal();
        } else if (!snap.hasData) {
          home = const StageBackground(child: SizedBox.expand());
        } else {
          home = const HomeScreen();
        }
        final app = MaterialApp(
          title: 'DanceAI',
          debugShowCheckedModeBanner: false,
          theme: buildStageTheme(),
          home: home,
        );
        return snap.hasData ? AppScope(services: snap.data!, child: app) : app;
      },
    );
  }
}

class _Fatal extends StatelessWidget {
  const _Fatal();

  @override
  Widget build(BuildContext context) => StageBackground(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Не удалось загрузить данные приложения. Переустановите приложение.',
              textAlign: TextAlign.center,
              style: StageText.body(15),
            ),
          ),
        ),
      );
}
