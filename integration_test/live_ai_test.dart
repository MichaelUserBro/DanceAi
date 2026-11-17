// ЖИВАЯ проверка адаптеров — только по команде автора (тратит лимиты).
// Полный путь пользователя: главный экран → танец → видео → «Оценить» →
// отчёт (или экран ошибки). Ключи — из переменных окружения, никуда не
// записываются и не выводятся:
//   DANCEAI_GOOGLE_KEY, DANCEAI_OPENROUTER_KEY
// Без LIVE=1 или без ключа нужного провайдера тест пропускается.
//
//   flutter test integration_test/live_ai_test.dart -d windows ^
//     --dart-define=LIVE=1 ^
//     --dart-define=LIVE_CASES=google/gemini-3.8-flash/frames,openrouter/nvidia/nemotron-3.5-super-vl:free/video ^
//     --dart-define=LIVE_VIDEOS=samba_1,slow_waltz_1 ^
//     --dart-define=OUT_DIR=C:\path\to\results
//
// Случай: <provider_id>/<модель>/<frames|video>; модель может содержать «/».
// Каждый случай × каждое видео = 1–2 запроса (второй — при повторе).
// OUT_DIR — куда сохранить JSON «Для разработчика» (без ключа).
//
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:dance_ai/analysis/analysis_export.dart';
import 'package:dance_ai/analysis/device_video_preparer.dart';
import 'package:dance_ai/analysis/temp_storage.dart';
import 'package:dance_ai/app/app.dart';
import 'package:dance_ai/app/app_scope.dart';
import 'package:dance_ai/data/app_data.dart';
import 'package:dance_ai/platform/video_picker.dart';
import 'package:dance_ai/settings/secure_key_store.dart';
import 'package:dance_ai/settings/settings_store.dart';
import 'package:dance_ai/ui/screens/error_screen.dart';
import 'package:dance_ai/ui/screens/report_screen.dart';
import 'package:dance_ai/ui/screens/warning_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

const _live = String.fromEnvironment('LIVE');
const _cases = String.fromEnvironment('LIVE_CASES');
const _videos = String.fromEnvironment('LIVE_VIDEOS');
const _outDir = String.fromEnvironment('OUT_DIR');
const _videoDir = String.fromEnvironment('VIDEO_DIR', defaultValue: 'test_videos');

const _envKeys = {
  'google': 'DANCEAI_GOOGLE_KEY',
  'openrouter': 'DANCEAI_OPENROUTER_KEY',
};

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

Future<void> _pumpUntil(WidgetTester tester, bool Function() done,
    {Duration timeout = const Duration(minutes: 12)}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('не дождались за $timeout');
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('живые запросы к ИИ: путь пользователя', (tester) async {
    if (_live != '1' || _cases.isEmpty) {
      print('LIVE пропущено: нужен --dart-define=LIVE=1 и LIVE_CASES');
      return;
    }
    final all = Directory(_videoDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp4'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final wanted = _videos.isEmpty ? null : _videos.split(',');
    final files = [
      for (final f in all)
        if (wanted == null ||
            wanted.any((w) => f.uri.pathSegments.last.startsWith(w)))
          f,
    ];
    if (files.isEmpty) {
      print('LIVE пропущено: нет видео');
      return;
    }

    tester.view.physicalSize = const Size(1400, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final data = await AppData.load();
    var requests = 0;
    print('LIVE | провайдер | модель | режим | видео | отправлено | время | '
        'с первого раза | оценки (tech/musicality/partnering/presentation) | '
        'status | итог');
    for (final spec in _cases.split(',')) {
      final first = spec.indexOf('/');
      final last = spec.lastIndexOf('/');
      final providerId = spec.substring(0, first);
      final model = spec.substring(first + 1, last);
      final mode = spec.substring(last + 1);
      final key = Platform.environment[_envKeys[providerId] ?? ''];
      if (key == null || key.isEmpty) {
        print('LIVE $spec пропущено: нет ${_envKeys[providerId]}');
        continue;
      }
      for (final file in files) {
        final name = file.uri.pathSegments.last;
        final picker = _FilePicker()..next = PickedVideo(source: file.path, name: name);
        final keys = MemoryKeyStore();
        final settings = SettingsStore(
            catalog: data.providers, prefs: MemoryPrefsStore(), keys: keys);
        await settings.load();
        await settings.selectProvider(providerId);
        await settings.setModel(providerId, model);
        await settings.saveKey(providerId, key);
        await settings.setVideoMode(providerId, mode == 'video');
        final services = AppServices(
          data: data,
          settings: settings,
          preparer: DeviceVideoPreparer(),
          tempStorage: TempStorage(),
          dev: DevState(),
          videoPicker: picker,
        );
        final dance = data.criteria.dance(_danceOf(name));

        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(DanceAiApp(servicesOverride: Future.value(services)));
        await _pumpUntil(tester, () => find.text(dance.nameRu).evaluate().isNotEmpty,
            timeout: const Duration(minutes: 1));
        await tester.pump(const Duration(seconds: 1));
        await tester.ensureVisible(find.text(dance.nameRu).first);
        await tester.tap(find.text(dance.nameRu).first);
        await _pumpUntil(tester, () => find.text('Выбрать видео').evaluate().isNotEmpty,
            timeout: const Duration(minutes: 1));
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.text('Выбрать видео'));
        await _pumpUntil(tester, () => find.text(name).evaluate().isNotEmpty,
            timeout: const Duration(minutes: 1));
        final start = find.text('Оценить');
        await tester.ensureVisible(start);
        await tester.pump(const Duration(milliseconds: 500));
        final sw = Stopwatch()..start();
        await tester.tap(start);
        await _pumpUntil(
            tester,
            () =>
                find.byType(ReportScreen).evaluate().isNotEmpty ||
                find.byType(WarningScreen).evaluate().isNotEmpty ||
                find.byType(ErrorScreen).evaluate().isNotEmpty);
        sw.stop();

        final t = services.dev.lastTrace!;
        requests += t.attempts.length;
        final report = t.reportJson;
        final scores = report == null
            ? '—'
            : [
                for (final c in (report['scores'] as Map? ?? const {}).values)
                  (c is Map ? c['couple'] : c),
              ].join('/');
        final status = (report?['video_assessment'] as Map?)?['status'] ?? '—';
        final sent = t.attempts.isEmpty ? null : t.attempts.first.sentBytes;
        print('LIVE | $providerId | $model | $mode | $name | '
            '${sent == null ? '—' : '${(sent / 1e6).toStringAsFixed(1)} MB'} | '
            '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(0)} s | '
            '${report == null ? '—' : (t.retried ? 'нет (повтор)' : 'да')} | '
            '$scores | $status | ${t.failure ?? 'отчёт'}');
        if (_outDir.isNotEmpty) {
          final out = File('$_outDir/${analysisExportFileName(t)}');
          await out.writeAsString(analysisExportText(t, data));
        }
        final text = analysisExportText(t, data);
        expect(text, isNot(contains(key)), reason: 'ключ не должен попасть в JSON');
      }
    }
    print('LIVE запросов к ИИ: $requests');
  }, timeout: const Timeout(Duration(minutes: 120)));
}
