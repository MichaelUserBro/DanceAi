import 'report.dart';

/// Общая оценка (spec 6): среднее четырёх оценок пары по компонентам,
/// округлённое до 0,1. Считает приложение, а не ИИ.
double overallScore(DanceReport report, List<String> componentIds) {
  final values = [for (final id in componentIds) report.scores[id]!.couple];
  return roundToTenth(values.reduce((a, b) => a + b) / values.length);
}

/// Округление до 0,1 (половина — вверх). Сумма целых / 4 даёт точные
/// двоичные дроби (.25, .5, .75), поэтому погрешности double здесь нет.
double roundToTenth(double value) => (value * 10).round() / 10;

/// «4,3» — с запятой, как принято в русском.
String formatScore(double value) =>
    value.toStringAsFixed(1).replaceAll('.', ',');
