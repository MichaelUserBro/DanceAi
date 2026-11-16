import 'dart:io';

import 'package:dance_ai/analysis/analysis_failure.dart';
import 'package:dance_ai/analysis/analysis_pipeline.dart';
import 'package:dance_ai/analysis/device_video_preparer.dart';
import 'package:dance_ai/analysis/temp_storage.dart';
import 'package:dance_ai/analysis/video_preparer.dart';
import 'package:dance_ai/app/app.dart';
import 'package:dance_ai/app/app_scope.dart';
import 'package:dance_ai/report/report.dart';
import 'package:dance_ai/settings/secure_key_store.dart';
import 'package:dance_ai/settings/settings_store.dart';
import 'package:dance_ai/theme/stage_theme.dart';
import 'package:dance_ai/ui/screens/developer_screen.dart';
import 'package:dance_ai/ui/screens/error_screen.dart';
import 'package:dance_ai/ui/screens/report_screen.dart';
import 'package:dance_ai/ui/screens/settings_screen.dart';
import 'package:dance_ai/ui/screens/warning_screen.dart';
import 'package:dance_ai/ui/video_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_media_tool.dart';
import 'test_data.dart';

AppServices makeServices() {
  final data = loadTestAppData();
  return AppServices(
    data: data,
    settings: SettingsStore(
      catalog: data.providers,
      prefs: MemoryPrefsStore(),
      keys: MemoryKeyStore(),
    ),
    preparer: DeviceVideoPreparer(tool: FakeMediaTool()),
    tempStorage: TempStorage(
        root: () async => Directory.systemTemp, isAndroid: false),
    dev: DevState(),
  );
}

Future<void> pumpScreen(WidgetTester tester, AppServices services, Widget screen,
    {Size size = const Size(420, 900)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(
    services: services,
    child: MaterialApp(theme: buildStageTheme(), home: screen),
  ));
  // Анимации появления и счётчики.
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  late AppServices services;
  setUp(() => services = makeServices());

  VideoSession session(String danceId) => VideoSession(
      dance: services.data.criteria.dance(danceId),
      tempStorage: services.tempStorage);

  testWidgets('главный экран: 4 танца в группах Стандарт и Латина',
      (tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        DanceAiApp(servicesOverride: Future.value(services)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('СТАНДАРТ'), findsOneWidget);
    expect(find.text('ЛАТИНА'), findsOneWidget);
    for (final d in services.data.criteria.dances) {
      expect(find.text(d.nameRu), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('главный экран на широком окне — без переполнений',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        DanceAiApp(servicesOverride: Future.value(services)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Медленный вальс'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(400, 900), const Size(1300, 900)]) {
    testWidgets('отчёт ${size.width.toInt()}px: краткий и подробный',
        (tester) async {
      final report = DanceReport.fromJson(loadExampleReportJson());
      await pumpScreen(
        tester,
        services,
        ReportScreen(
          report: report,
          dance: services.data.criteria.dance('slow_waltz'),
          session: session('slow_waltz'),
        ),
        size: size,
      );
      expect(find.text('Общая оценка'), findsOneWidget);
      expect(find.text('4,5'), findsOneWidget);
      expect(find.text('Главные ошибки'), findsOneWidget);
      expect(find.text('Над чем работать'), findsOneWidget);

      await tester.tap(find.text('Подробно'));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Все ошибки'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Подробный разбор'), 400,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Подробный разбор'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Разбор по людям'), 400,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Разбор по людям'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('предупреждение при low_confidence: причины и два действия',
      (tester) async {
    final json = loadExampleReportJson();
    (json['video_assessment'] as Map)['status'] = 'low_confidence';
    await pumpScreen(
      tester,
      services,
      WarningScreen(
        report: DanceReport.fromJson(json),
        dance: services.data.criteria.dance('slow_waltz'),
        session: session('slow_waltz'),
      ),
    );
    expect(find.text('Оценка неточная'), findsOneWidget);
    expect(find.text('Показать оценку всё равно'), findsOneWidget);
    expect(find.text('Загрузить другое видео'), findsOneWidget);
    expect(find.textContaining('треть времени'), findsOneWidget);
  });

  testWidgets('ошибка: текст и действия', (tester) async {
    await pumpScreen(
      tester,
      services,
      ErrorScreen(
        failure: const AnalysisFailure(FailureKind.invalidKey),
        session: session('samba'),
      ),
    );
    expect(find.text('Неверный ключ API'), findsOneWidget);
    expect(find.text('Открыть настройки'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
  });

  testWidgets('настройки: провайдеры по алфавиту + «Свой», ключ скрыт',
      (tester) async {
    await pumpScreen(tester, services, const SettingsScreen(),
        size: const Size(1300, 1000));
    final names = [for (final p in services.data.providers.all) p.name];
    for (final n in names) {
      expect(find.text(n), findsOneWidget);
    }
    expect(find.text('Своя модель'), findsOneWidget);
    expect(find.text('Лицензии'), findsOneWidget);

    await tester.tap(find.text(names.first));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Модель принимает видео со звуком'), findsOneWidget);
    final keyField = tester.widget<TextField>(find.ancestor(
        of: find.text('Ключ API'), matching: find.byType(TextField)));
    expect(keyField.obscureText, isTrue);
    expect(services.settings.provider!.name, names.first);
    expect(tester.takeException(), isNull);
  });

  testWidgets('для разработчика: сценарии заглушки', (tester) async {
    await pumpScreen(tester, services, const DeveloperScreen());
    expect(find.text('Нормальный ответ'), findsOneWidget);
    expect(find.text('Нет сети'), findsOneWidget);
    await tester.tap(find.text('Нет сети'));
    await tester.pump();
    expect(services.settings.stubScenario.id, 'network');
  });

  testWidgets('для разработчика: подготовка последнего видео', (tester) async {
    final trace = AnalysisTrace();
    trace.prepare
      ..durationSec = 92
      ..hasAudio = true
      ..frameCount = 120
      ..requestedFps = 2
      ..actualFps = 1.3
      ..thinned = true
      ..bpm = 87.2
      ..musicConfidence = 0.61
      ..musicText = 'Темп: 87 BPM (29 тактов/мин), размер 3/4.'
      ..stageTimes[PrepareStage.checkingVideo] = const Duration(milliseconds: 40)
      ..stageTimes[PrepareStage.extractingFrames] = const Duration(seconds: 6);
    services.dev.record(trace);
    await pumpScreen(tester, services, const DeveloperScreen(),
        size: const Size(1300, 1200));
    expect(find.text('Подготовка видео'), findsOneWidget);
    expect(find.textContaining('120, 1,3 кадр/с'), findsOneWidget);
    expect(find.textContaining('87,2 BPM'), findsOneWidget);
    expect(find.textContaining('всего 6 с'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
