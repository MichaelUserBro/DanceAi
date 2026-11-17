/// Ближайшая полночь по тихоокеанскому времени (сброс дневных квот
/// бесплатных тарифов) — в часах по Москве: 11:00 зимой (PST, UTC−8),
/// 10:00 летом (PDT, UTC−7). МСК — UTC+3 круглый год.
String pacificMidnightMsk([DateTime? nowUtc]) {
  final now = (nowUtc ?? DateTime.now()).toUtc();
  // Дата ближайшей полуночи по Тихоокеанскому времени (сдвиг −8 достаточно
  // точен, чтобы выбрать день).
  final pacificNow = now.subtract(const Duration(hours: 8));
  final next = DateTime.utc(pacificNow.year, pacificNow.month, pacificNow.day + 1);
  final hour = _usDstAtMidnight(next) ? 10 : 11;
  return '$hour:00';
}

/// Летнее время США: со 2-го воскресенья марта 2:00 до 1-го воскресенья
/// ноября 2:00. Полночь дня перехода — ещё по старому времени.
bool _usDstAtMidnight(DateTime day) {
  final start = _nthSunday(day.year, 3, 2);
  final end = _nthSunday(day.year, 11, 1);
  return day.isAfter(start) && !day.isAfter(end);
}

DateTime _nthSunday(int year, int month, int n) {
  final first = DateTime.utc(year, month, 1);
  final offset = (DateTime.sunday - first.weekday) % 7;
  return DateTime.utc(year, month, 1 + offset + 7 * (n - 1));
}

/// Подставляет `{{pacific_midnight_msk}}` в подсказку из providers.json.
String fillQuotaHint(String hint, [DateTime? nowUtc]) =>
    hint.replaceAll('{{pacific_midnight_msk}}', pacificMidnightMsk(nowUtc));
