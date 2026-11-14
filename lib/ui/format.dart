/// Русское склонение: plural(5, 'фигура', 'фигуры', 'фигур') → «фигур».
String plural(int n, String one, String few, String many) {
  final mod100 = n % 100;
  final mod10 = n % 10;
  if (mod100 >= 11 && mod100 <= 14) return many;
  if (mod10 == 1) return one;
  if (mod10 >= 2 && mod10 <= 4) return few;
  return many;
}

String countLabel(int n, String one, String few, String many) =>
    '$n ${plural(n, one, few, many)}';

/// 93.4 → «1:33».
String formatDuration(double? seconds) {
  if (seconds == null) return 'неизвестно';
  final total = seconds.round();
  final m = total ~/ 60;
  final s = (total % 60).toString().padLeft(2, '0');
  return '$m:$s';
}
