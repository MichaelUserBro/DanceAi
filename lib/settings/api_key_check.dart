/// Очистка и проверка ключа API (spec 7.2). Ключ уходит в заголовок HTTP,
/// а там допустимы только печатные символы ASCII: невидимый символ,
/// перенос строки посередине или русская буква дают FormatException в
/// dart:io (с ключом в тексте исключения) ещё до отправки запроса.
library;

/// Результат проверки: очищенный ключ или описание недопустимого символа
/// (без самого ключа).
class ApiKeyCheck {
  const ApiKeyCheck._(this.key, this.badChar, this.badIndex);

  /// Очищенный ключ (пустой — ключа нет).
  final String key;

  /// Первый недопустимый символ после очистки (`U+0416`) и его позиция;
  /// null — ключ годен.
  final String? badChar;
  final int? badIndex;

  bool get ok => badChar == null;

  /// Для «Для разработчика» и JSON: без значения ключа.
  String get problem => ok
      ? ''
      : 'недопустимый символ $badChar в позиции ${badIndex! + 1} '
          '(длина ключа ${key.length})';
}

/// Невидимые символы, которые попадают в ключ при копировании (мессенджеры,
/// PDF, заметки): пробелы нулевой ширины, мягкий перенос, BOM.
bool _invisible(int c) =>
    (c >= 0x200B && c <= 0x200F) ||
    (c >= 0x2060 && c <= 0x2064) ||
    c == 0xFEFF ||
    c == 0x00AD ||
    c == 0x180E;

/// Пробельные и управляющие символы (в т. ч. перенос строки посередине,
/// неразрывный пробел) — в ключах API их не бывает.
bool _space(int c) =>
    c <= 0x20 ||
    c == 0x7F ||
    c == 0x00A0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000;

/// Убирает пробелы, переводы строк и невидимые символы по всей строке; если
/// остались символы вне печатного ASCII (0x21–0x7E) — ключ не годен.
ApiKeyCheck checkApiKey(String raw) {
  final b = StringBuffer();
  for (final r in raw.runes) {
    if (_space(r) || _invisible(r)) continue;
    b.writeCharCode(r);
  }
  final key = b.toString();
  var i = 0;
  for (final r in key.runes) {
    if (r < 0x21 || r > 0x7E) {
      final hex = r.toRadixString(16).toUpperCase().padLeft(4, '0');
      return ApiKeyCheck._(key, 'U+$hex', i);
    }
    i++;
  }
  return ApiKeyCheck._(key, null, null);
}

/// Текст для пользователя, если ключ не годен.
const String apiKeyBadCharsRu =
    'В ключе есть недопустимые символы (например, русские буквы). '
    'Скопируйте ключ заново со страницы провайдера и вставьте его целиком.';
