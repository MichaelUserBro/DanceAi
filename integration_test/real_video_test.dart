// Проверка в приложении ровно путём пользователя, с настоящим FFmpeg и
// изолятом анализа музыки: главный экран → танец → видео → «Оценить» →
// отчёт → «Для разработчика». Видео — локальные, в репозиторий не входят:
//   Windows: test_videos/ (по умолчанию) или --dart-define=VIDEO_DIR=...
//   Android: <внешняя папка приложения>/bench (скопировать через adb push).
// Нет видео — тест пропускается.
//
//   flutter test integration_test/real_video_test.dart -d windows
//   flutter test integration_test/real_video_test.dart -d <android-id>
//
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:dance_ai/analysis/device_video_preparer.dart';
import 'package:dance_ai/analysis/temp_storage.dart';
import 'package:dance_ai/app/app.dart';
import 'package:dance_ai/app/app_scope.dart';
import 'package:dance_ai/data/app_data.dart';
import 'package:dance_ai/platform/video_picker.dart';
import 'package:dance_ai/report/report.dart';
import 'package:dance_ai/settings/secure_key_store.dart';
import 'package:dance_ai/settings/settings_store.dart';
import 'package:dance_ai/ui/screens/developer_screen.dart';
import 'package:dance_ai/ui/screens/report_screen.dart';
import 'package:dance_ai/ui/screens/warning_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

const _videoDirDefine = String.fromEnvironment('VIDEO_DIR');

/// Выбор видео без системного диалога: отдаёт заданный файл.
class _FilePicker implements VideoPicker {
  PickedVideo? next;
  @override
  Future<PickedVideo?> pick({required String danceId}) async => next;
  @override
  Future<RestoredPick?> takeRestored() async => null;
  @override
  Future<void> release(PickedVideo video) async {}
}

String _danceOf(String name) {
  final n = name.toLowerCase();
  if (n.contains('cha')) return 'cha_cha';
  if (n.contains('quick')) return 'quickstep';
  if (n.contains('samba')) return 'samba';
  return 'slow_waltz';
}

Future<Directory> _videoDir() async {
  if (_videoDirDefine.isNotEmpty) return Directory(_videoDirDefine);
  if (Platform.isAndroid) {
    return Directory('${(await getExternalStorageDirectory())!.path}/bench');
  }
  return Directory('test_videos');
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() done,
    {Duration timeout = const Duration(minutes: 3)}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('не дождались за $timeout');
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('реальные видео: подготовка и анализ музыки в приложении',
      (tester) async {
    final dir = await _videoDir();
    final files = dir.existsSync()
        ? (dir.listSync().whereType<File>().where((f) =>
                RegExp(r'\.(mp4|mov)$', caseSensitive: false).hasMatch(f.path))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
        : <File>[];
    if (files.isEmpty) {
      print('REAL пропущено: нет видео в ${dir.path}');
      return;
    }

    // Широкое высокое окно: на «Для разработчика» всё видно без прокрутки.
    tester.view.physicalSize = const Size(1400, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final data = await AppData.load();
    final picker = _FilePicker();
    final services = AppServices(
      data: data,
      settings: SettingsStore(
          catalog: data.providers,
          prefs: MemoryPrefsStore(),
          keys: MemoryKeyStore()),
      preparer: DeviceVideoPreparer(),
      tempStorage: TempStorage(),
      dev: DevState(),
      videoPicker: picker,
    );
    await services.settings.load();
    // Без ключа: настоящая подготовка видео и анализ музыки, ИИ — заглушка.
    await services.settings.setDemoMode(true);

    final rows = <String>[];
    for (final file in files) {
      final name = file.uri.pathSegments.last;
      final dance = data.criteria.dance(_danceOf(name));
      picker.next = PickedVideo(source: file.path, name: name);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
          DanceAiApp(servicesOverride: Future.value(services)));
      await _pumpUntil(tester, () => find.text(dance.nameRu).evaluate().isNotEmpty);
      await tester.pump(const Duration(seconds: 1));

      // Танец → экран «Видео».
      await tester.ensureVisible(find.text(dance.nameRu).first);
      await tester.tap(find.text(dance.nameRu).first);
      await _pumpUntil(
          tester, () => find.text('Выбрать видео').evaluate().isNotEmpty);
      await tester.pump(const Duration(seconds: 1));

      // Выбор файла → проверка FFmpeg (probe).
      await tester.tap(find.text('Выбрать видео'));
      await _pumpUntil(tester, () => find.text(name).evaluate().isNotEmpty);

      // «Оценить» → подготовка (FFmpeg + изолят) → заглушка ИИ → отчёт.
      final start = find.text('Оценить');
      await tester.ensureVisible(start);
      await tester.pump(const Duration(milliseconds: 500));
      final sw = Stopwatch()..start();
      await tester.tap(start);
      await _pumpUntil(
          tester,
          () =>
              find.byType(ReportScreen).evaluate().isNotEmpty ||
              find.byType(WarningScreen).evaluate().isNotEmpty);
      sw.stop();

      // «Для разработчика».
      final shown = find.byType(ReportScreen).evaluate().isNotEmpty
          ? find.byType(ReportScreen)
          : find.byType(WarningScreen);
      final nav = Navigator.of(tester.element(shown));
      nav.push(MaterialPageRoute<void>(builder: (_) => const DeveloperScreen()));
      await _pumpUntil(tester,
          () => find.byType(DeveloperScreen).evaluate().isNotEmpty,
          timeout: const Duration(seconds: 20));
      await tester.pump(const Duration(seconds: 2));
      String line(String key) {
        String plain(Widget w) => w is Text
            ? (w.textSpan?.toPlainText() ?? w.data ?? '')
            : '';
        final f = find.byWidgetPredicate((w) => plain(w).startsWith('$key:'));
        return f.evaluate().isEmpty ? '—' : plain(f.evaluate().first.widget);
      }

      final d = services.dev.lastTrace!.prepare;
      final level = line('Уровень звука');
      final tempo = line('Темп');
      print('REAL $name | ${dance.id} | $level | $tempo | notes ${d.notes} | ${sw.elapsedMilliseconds} ms');
      rows.add(name);

      expect(d.notes.where((n) => n.contains('unsendable')), isEmpty);
      expect(d.audioRmsDb, isNotNull, reason: '$name: уровень звука');
      expect(d.bpm, isNotNull, reason: '$name: ${d.notes}');
      expect(d.musicConfidence, isNotNull);
      expect(level, contains('дБ'));
      expect(tempo, contains('BPM'));
      expect(tempo, contains('уверенность'));
      expect(d.musicText, contains('Уверенность анализа:'));
      expect(services.dev.lastTrace!.prompt, isNotNull);
      expect(VideoStatus.values, isNotEmpty);
    }
    expect(rows, hasLength(files.length));
  }, timeout: const Timeout(Duration(minutes: 20)));
}
