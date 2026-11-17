import 'dart:convert';
import 'dart:typed_data';

import 'package:dance_ai/analysis/ai_provider.dart';
import 'package:dance_ai/analysis/prompt_builder.dart';
import 'package:dance_ai/platform/file_saver.dart';
import 'dart:io';

import 'package:dance_ai/analysis/analysis_failure.dart';
import 'package:dance_ai/analysis/analysis_pipeline.dart';
import 'package:dance_ai/analysis/device_video_preparer.dart';
import 'package:dance_ai/analysis/media/media_tool.dart';
import 'package:dance_ai/analysis/music/music_analyzer.dart';
import 'package:dance_ai/analysis/temp_storage.dart';
import 'package:dance_ai/analysis/video_preparer.dart';
import 'package:dance_ai/app/app.dart';
import 'package:dance_ai/app/app_scope.dart';
import 'package:dance_ai/platform/video_picker.dart';
import 'package:dance_ai/report/report.dart';
import 'package:dance_ai/settings/secure_key_store.dart';
import 'package:dance_ai/settings/settings_store.dart';
import 'package:dance_ai/theme/stage_theme.dart';
import 'package:dance_ai/ui/screens/developer_screen.dart';
import 'package:dance_ai/ui/screens/error_screen.dart';
import 'package:dance_ai/ui/screens/report_screen.dart';
import 'package:dance_ai/ui/screens/settings_screen.dart';
import 'package:dance_ai/ui/screens/video_screen.dart';
import 'package:dance_ai/ui/screens/warning_screen.dart';
import 'package:dance_ai/ui/video_session.dart';
import 'package:dance_ai/ui/widgets/common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_media_tool.dart';
import 'fake_video_picker.dart';
import 'test_data.dart';

AppServices makeServices({FakeMediaTool? tool, FakeVideoPicker? picker}) {
  final data = loadTestAppData();
  return AppServices(
    data: data,
    settings: SettingsStore(
      catalog: data.providers,
      prefs: MemoryPrefsStore(),
      keys: MemoryKeyStore(),
    ),
    preparer: DeviceVideoPreparer(tool: tool ?? FakeMediaTool()),
    tempStorage: TempStorage(
        root: () async => Directory.systemTemp, isAndroid: false),
    dev: DevState(),
    videoPicker: picker ?? FakeVideoPicker(),
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
      picker: services.videoPicker);

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

  testWidgets('отчёт: у партнёрши нет части оценок — линия и пометка есть',
      (tester) async {
    final json = loadExampleReportJson();
    final scores = json['scores'] as Map<String, dynamic>;
    final ids = scores.keys.toList();
    (scores[ids[1]] as Map)['follower'] = null;
    (scores[ids[3]] as Map)['leader'] = null;
    final report = DanceReport.fromJson(json);
    await pumpScreen(
      tester,
      services,
      ReportScreen(
        report: report,
        dance: services.data.criteria.dance('slow_waltz'),
        session: session('slow_waltz'),
      ),
      size: const Size(1300, 1000),
    );
    final names = {
      for (final c in services.data.criteria.components) c.id: c.nameRu,
    };
    expect(find.text('Партнёрша'), findsWidgets);
    expect(find.text(' · нет оценки: ${names[ids[1]]}'), findsOneWidget);
    expect(find.text(' · нет оценки: ${names[ids[3]]}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
    await tester.ensureVisible(find.text('Нет сети'));
    await tester.pump();
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
      ..musicLevel = MusicConfidence.medium
      ..audioRmsDb = -15.2
      ..audioPeakDb = -2.1
      ..musicPeriodicity = 0.1
      ..musicAgreement = 0.94
      ..musicText = 'Темп: 87 BPM (29 тактов/мин), размер 3/4.'
      ..stageTimes[PrepareStage.checkingVideo] = const Duration(milliseconds: 40)
      ..stageTimes[PrepareStage.extractingFrames] = const Duration(seconds: 6);
    services.dev.record(trace);
    await pumpScreen(tester, services, const DeveloperScreen(),
        size: const Size(1300, 1200));
    expect(find.text('Подготовка видео'), findsOneWidget);
    expect(find.textContaining('120, 1,3 кадр/с'), findsOneWidget);
    expect(find.textContaining('87,2 BPM'), findsOneWidget);
    expect(find.textContaining('(средняя)'), findsOneWidget);
    expect(find.textContaining('средний -15,2 дБ'), findsOneWidget);
    expect(find.textContaining('совпал в 94 %'), findsOneWidget);
    expect(find.textContaining('всего 6 с'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('для разработчика: демо-режим, частота видео, запросы к ИИ, '
      '«Сохранить JSON»', (tester) async {
    final trace = AnalysisTrace()
      ..danceId = 'samba'
      ..providerName = 'Google (Gemini)'
      ..model = 'gemini-3.8-flash'
      ..mode = SubmissionMode.video
      ..videoFps = 2
      ..startedAt = DateTime(2026, 11, 17, 10)
      ..totalTime = const Duration(seconds: 41)
      ..prompt = const BuiltPrompt(system: 'S', user: 'U')
      ..responses.addAll(['{}', '{}']);
    trace.prepare
      ..lightVideoBytes = 6 * 1024 * 1024
      ..lightVideoCodec = 'h264_mf'
      ..lightVideoWidth = 480
      ..lightVideoHeight = 854;
    trace.attempts
      ..add(AiAttempt(retry: false)
        ..sentBytes = 8 * 1024 * 1024
        ..totalTime = const Duration(seconds: 20)
        ..usage = const AiUsage(inputTokens: 12000, outputTokens: 3000, thinkingTokens: 900))
      ..add(AiAttempt(retry: true, reason: AttemptReason.invalidResponse)
        ..totalTime = const Duration(seconds: 18));
    services.dev.record(trace);
    final saver = _MemorySaver();
    await pumpScreen(tester, services, DeveloperScreen(saver: saver),
        size: const Size(1300, 2400));
    expect(find.text('Демо-режим (без ИИ)'), findsOneWidget);
    expect(find.textContaining('6,0 МБ, 480×854, h264_mf'), findsOneWidget);
    expect(find.textContaining('модель смотрит 2 кадр/с'), findsOneWidget);
    expect(find.textContaining('был (первый ответ'), findsOneWidget);
    expect(find.textContaining('вход 12000, выход 3000, размышление 900'),
        findsOneWidget);

    await tester.tap(find.text('4 кадр/с'));
    await tester.pump();
    expect(services.settings.videoFps, 4);
    await tester.tap(find.text('Демо-режим (без ИИ)'));
    await tester.pump();
    expect(services.settings.demoMode, isTrue);

    await tester.ensureVisible(find.text('Сохранить JSON'));
    await tester.tap(find.text('Сохранить JSON'));
    await tester.pump(const Duration(seconds: 1));
    expect(saver.name, 'danceai_samba_gemini-3.8-flash_20261117-100000.json');
    final j = jsonDecode(utf8.decode(saver.bytes!)) as Map<String, dynamic>;
    expect(j['submission']['video_codec'], 'h264_mf');
    expect(j['attempts'], hasLength(2));
    expect(find.text('JSON сохранён'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('экран «Видео»', () {
    const big = PickedVideo(
        source: 'content://media/document/video%3A1',
        name: 'VID_big.mp4',
        sizeBytes: 390000000);

    Future<void> pickOnScreen(WidgetTester tester, AppServices s) async {
      await pumpScreen(
          tester, s, VideoScreen(dance: s.data.criteria.dance('samba')),
          size: const Size(1300, 900));
      await tester.tap(find.text('Выбрать видео'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 9));
    }

    testWidgets('выбор по URI: видео принято, превью недоступно — '
        'анализ не блокируется', (tester) async {
      final picker = FakeVideoPicker(next: big);
      final s = makeServices(picker: picker);
      await pickOnScreen(tester, s);
      expect(picker.picks, ['samba']);
      expect(find.text('VID_big.mp4'), findsOneWidget);
      // В тестах платформенного плеера нет — как при неподдерживаемом кодеке.
      expect(find.text('Превью недоступно — анализ это не мешает'),
          findsOneWidget);
      final start = tester.widget<PrimaryButton>(
          find.widgetWithText(PrimaryButton, 'Оценить'));
      expect(start.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('URI недоступен → «Не удалось открыть видео, выберите его '
        'заново», право освобождено', (tester) async {
      final picker = FakeVideoPicker(next: big);
      final s = makeServices(picker: picker, tool: FakeMediaTool(info: null));
      await pickOnScreen(tester, s);
      expect(find.text(unreadableVideoMessage), findsOneWidget);
      expect(find.text('VID_big.mp4'), findsNothing);
      expect(picker.released, [big.source]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ошибка выбора — сообщение, не вылет', (tester) async {
      final picker = FakeVideoPicker(
          error: const VideoPickException('Не удалось открыть выбор файла.'));
      await pickOnScreen(tester, makeServices(picker: picker));
      expect(find.text('Не удалось открыть выбор файла.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('после выгрузки приложения открывается экран «Видео» '
        'с выбранным файлом', (tester) async {
      final picker = FakeVideoPicker(
          restored: const RestoredPick(danceId: 'quickstep', video: big));
      final s = makeServices(picker: picker);
      tester.view.physicalSize = const Size(1300, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(DanceAiApp(servicesOverride: Future.value(s)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(VideoScreen), findsOneWidget);
      expect(find.text('Квикстеп'), findsWidgets);
      expect(find.text('VID_big.mp4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  test('VideoProbe для MediaInfo без видео — не читается', () async {
    final p = await DeviceVideoPreparer(
            tool: FakeMediaTool(
                info: const MediaInfo(
                    durationSec: 3, hasAudio: true, hasVideo: false)))
        .probe('x');
    expect(p.readable, isFalse);
  });
}

class _MemorySaver implements FileSaver {
  String? name;
  Uint8List? bytes;

  @override
  Future<bool> save(
      {required String name,
      required Uint8List bytes,
      String mime = 'application/json'}) async {
    this.name = name;
    this.bytes = bytes;
    return true;
  }
}
