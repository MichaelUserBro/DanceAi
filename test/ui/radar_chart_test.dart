import 'package:dance_ai/report/report.dart';
import 'package:dance_ai/theme/stage_theme.dart';
import 'package:dance_ai/ui/widgets/radar_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const axes = ['Техника', 'Музыка', 'Партнёрство', 'Хореография'];

RadarSeries series(String label, List<int?> values, {bool filled = false}) =>
    RadarSeries(
        label: label, color: Colors.amber, values: values, filled: filled);

Future<void> pumpRadar(WidgetTester tester, List<RadarSeries> s) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildStageTheme(),
    home: Scaffold(
      body: SizedBox(width: 420, child: RadarChart(axes: axes, series: s)),
    ),
  ));
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  group('radarSegments', () {
    test('все оценки — замкнутая линия', () {
      expect(radarSegments([5, 6, 7, 5]), [
        (from: 0, to: 1),
        (from: 1, to: 2),
        (from: 2, to: 3),
        (from: 3, to: 0),
      ]);
    });

    test('пропуск — разрыв на этой оси, остальное соединено', () {
      expect(radarSegments([5, 6, null, 5]), [
        (from: 0, to: 1),
        (from: 3, to: 0),
      ]);
    });

    test('две оценки на соседних осях — один отрезок; на противоположных — '
        'только точки (линия не идёт через центр)', () {
      expect(radarSegments([5, null, null, 6]), [(from: 3, to: 0)]);
      expect(radarSegments([5, null, 6, null]), isEmpty);
    });

    test('одна оценка или ни одной — без линий', () {
      expect(radarSegments([null, 7, null, null]), isEmpty);
      expect(radarSegments([null, null, null, null]), isEmpty);
    });

    test('отрезки никогда не касаются оси без оценки', () {
      for (final values in [
        [4, null, 6, null],
        [null, 3, 4, 5],
        [2, 3, null, null],
      ]) {
        for (final s in radarSegments(values)) {
          expect(values[s.from], isNotNull);
          expect(values[s.to], isNotNull);
        }
      }
    });
  });

  group('легенда', () {
    testWidgets('полные данные — все трое без пометок', (tester) async {
      await pumpRadar(tester, [
        series('Пара', [5, 5, 5, 5], filled: true),
        series('Партнёр', [5, 6, 5, 4]),
        series('Партнёрша', [6, 5, 5, 5]),
      ]);
      for (final l in ['Пара', 'Партнёр', 'Партнёрша']) {
        expect(find.text(l), findsOneWidget);
      }
      expect(find.textContaining('нет оценки'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('пропуски у одного — он в легенде с пометкой', (tester) async {
      await pumpRadar(tester, [
        series('Пара', [5, 5, 5, 5], filled: true),
        series('Партнёр', [5, 6, 5, 4]),
        series('Партнёрша', [6, null, 5, null]),
      ]);
      expect(find.text('Партнёрша'), findsOneWidget);
      expect(find.text(' · нет оценки: Музыка, Хореография'), findsOneWidget);
      expect(find.textContaining('нет оценки'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('пропуски у обоих — оба в легенде, у каждого свои',
        (tester) async {
      await pumpRadar(tester, [
        series('Пара', [5, 5, 5, 5], filled: true),
        series('Партнёр', [null, 6, 5, 4]),
        series('Партнёрша', [6, null, null, 5]),
      ]);
      expect(find.text('Партнёр'), findsOneWidget);
      expect(find.text('Партнёрша'), findsOneWidget);
      expect(find.text(' · нет оценки: Техника'), findsOneWidget);
      expect(find.text(' · нет оценки: Музыка, Партнёрство'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('без личных оценок — только пара', (tester) async {
      await pumpRadar(tester, [
        series('Пара', [5, 5, 5, 5], filled: true),
        series('Партнёр', [null, null, null, null]),
        series('Партнёрша', [null, null, null, null]),
      ]);
      expect(find.text('Пара'), findsOneWidget);
      expect(find.text('Партнёр'), findsNothing);
      expect(find.text('Партнёрша'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  test('hasPersonScores: хватает одной оценки', () {
    expect(
        const ComponentScore(couple: 5, leader: null, follower: 4, comment: '')
            .of(Who.follower),
        4);
  });
}
