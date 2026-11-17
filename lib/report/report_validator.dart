import 'dart:convert';

import '../data/criteria.dart';
import 'report.dart';
import 'report_rules.dart';

/// Проверка ответа ИИ (spec 7.7 п. 2): формат по схеме + соответствие
/// criteria.json. Возвращает список проблем на русском (пустой — всё в порядке).
/// Тексты проблем уходят в повторный запрос к ИИ и в раздел «Для разработчика».
class ReportValidator {
  const ReportValidator(this.catalog);

  final CriteriaCatalog catalog;

  List<String> validate(Object? json, {required Dance dance}) {
    final problems = <String>[];
    _checkRule(json, reportRule, r'$', problems);
    if (problems.isNotEmpty) return problems;
    _checkSemantics(json as Map<String, dynamic>, dance, problems);
    return problems;
  }

  void _checkRule(Object? value, JsonRule rule, String path, List<String> out) {
    if (value == null) {
      if (!rule.nullable) out.add('$path: значение не может быть null');
      return;
    }
    switch (rule) {
      case StringRule(:final values):
        if (value is! String) {
          out.add('$path: ожидается строка');
        } else if (values != null && !values.contains(value)) {
          out.add('$path: недопустимое значение "$value", '
              'допустимо: ${values.join(', ')}');
        }
      case IntRule(:final min, :final max):
        if (value is! int) {
          out.add('$path: ожидается целое число');
        } else if ((min != null && value < min) || (max != null && value > max)) {
          out.add('$path: значение $value вне диапазона '
              '${min ?? '…'}–${max ?? '…'}');
        }
      case ArrayRule(:final items, :final minItems, :final maxItems):
        if (value is! List) {
          out.add('$path: ожидается массив');
          return;
        }
        if (minItems != null && value.length < minItems) {
          out.add('$path: элементов ${value.length}, нужно не меньше $minItems');
        }
        if (maxItems != null && value.length > maxItems) {
          out.add('$path: элементов ${value.length}, нужно не больше $maxItems');
        }
        for (var i = 0; i < value.length; i++) {
          _checkRule(value[i], items, '$path[$i]', out);
        }
      case ObjectRule(:final properties):
        if (value is! Map<String, dynamic>) {
          out.add('$path: ожидается объект');
          return;
        }
        for (final key in value.keys) {
          if (!properties.containsKey(key)) {
            out.add('$path: лишнее поле "$key"');
          }
        }
        for (final entry in properties.entries) {
          if (!value.containsKey(entry.key)) {
            out.add('$path: нет обязательного поля "${entry.key}"');
          } else {
            _checkRule(value[entry.key], entry.value, '$path.${entry.key}', out);
          }
        }
    }
  }

  void _checkSemantics(
      Map<String, dynamic> json, Dance dance, List<String> out) {
    if (json['dance_id'] != dance.id) {
      out.add('\$.dance_id: ожидается "${dance.id}", получено "${json['dance_id']}"');
    }

    final criteria = catalog.criteriaFor(dance);
    final byId = {for (final c in criteria) c.id: c};
    final figureIds = {for (final f in dance.figures) f.id};

    // Каждый критерий ровно один раз, лишних нет.
    final results = (json['criteria_results'] as List).cast<Map<String, dynamic>>();
    final seen = <String, int>{};
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      final id = r['criterion_id'] as String;
      final path = '\$.criteria_results[$i]';
      seen[id] = (seen[id] ?? 0) + 1;
      final criterion = byId[id];
      if (criterion == null) {
        out.add('$path.criterion_id: "$id" — нет такого критерия у танца');
        continue;
      }
      if (criterion.perPerson) {
        if (r['leader'] == null || r['follower'] == null) {
          out.add('$path: у критерия "$id" отдельно партнёр и партнёрша: да — '
              'leader и follower не могут быть null');
        }
      } else if (r['leader'] != null || r['follower'] != null) {
        out.add('$path: у критерия "$id" отдельно партнёр и партнёрша: нет — '
            'leader и follower должны быть null');
      }
    }
    for (final e in seen.entries) {
      if (e.value > 1 && byId.containsKey(e.key)) {
        out.add('\$.criteria_results: критерий "${e.key}" встречается ${e.value} раза');
      }
    }
    final missing = [for (final c in criteria) if (!seen.containsKey(c.id)) c.id];
    if (missing.isNotEmpty) {
      out.add('\$.criteria_results: нет вердикта по критериям: ${missing.join(', ')}');
    }

    final figures = (json['figures'] as List).cast<Map<String, dynamic>>();
    for (var i = 0; i < figures.length; i++) {
      final id = figures[i]['figure_id'];
      if (id != null && !figureIds.contains(id)) {
        out.add('\$.figures[$i].figure_id: "$id" — нет такой фигуры у танца '
            '(для фигуры не из списка — null)');
      }
    }

    final errors = (json['errors'] as List).cast<Map<String, dynamic>>();
    for (var i = 0; i < errors.length; i++) {
      final c = errors[i]['criterion_id'];
      final f = errors[i]['figure_id'];
      if (c != null && !byId.containsKey(c)) {
        out.add('\$.errors[$i].criterion_id: "$c" — нет такого критерия у танца');
      }
      if (f != null && !figureIds.contains(f)) {
        out.add('\$.errors[$i].figure_id: "$f" — нет такой фигуры у танца');
      }
    }
  }
}

/// Результат разбора ответа ИИ.
sealed class ParseOutcome {
  const ParseOutcome();
}

class ParsedReport extends ParseOutcome {
  const ParsedReport(this.report, [this.json = const {}]);
  final DanceReport report;

  /// Отчёт как его вернула модель (для «Сохранить JSON»).
  final Map<String, dynamic> json;
}

class InvalidReport extends ParseOutcome {
  const InvalidReport(this.problems, {required this.notJson});
  final List<String> problems;

  /// Ответ — вообще не JSON-объект.
  final bool notJson;
}

/// Убирает возможную обёртку ```json … ``` (spec 7.7 п. 1).
String stripCodeFence(String raw) {
  var text = raw.trim();
  final fence = RegExp(r'^```[a-zA-Z0-9_-]*\s*\n?([\s\S]*?)\n?```\s*$');
  final m = fence.firstMatch(text);
  if (m != null) text = m.group(1)!.trim();
  return text;
}

/// Снятие обёртки → JSON → проверка → модель.
ParseOutcome parseReport(String raw,
    {required Dance dance, required ReportValidator validator}) {
  final text = stripCodeFence(raw);
  Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    // Модель могла добавить текст до или после объекта — берём сам объект.
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        json = jsonDecode(text.substring(start, end + 1));
      } on FormatException {
        json = null;
      }
    }
    if (json == null) {
      return const InvalidReport(
          ['Ответ не является JSON-объектом. Верни только JSON по схеме.'],
          notJson: true);
    }
  }
  if (json is! Map<String, dynamic>) {
    return const InvalidReport(
        ['Ответ — не JSON-объект. Верни один JSON-объект по схеме.'],
        notJson: true);
  }
  final problems = validator.validate(json, dance: dance);
  if (problems.isNotEmpty) return InvalidReport(problems, notJson: false);
  return ParsedReport(DanceReport.fromJson(json), json);
}
