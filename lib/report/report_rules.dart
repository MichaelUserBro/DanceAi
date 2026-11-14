// Правила формата отчёта — зеркало assets/report.schema.json в коде.
// Полная проверка по JSON Schema без внешнего пакета: обязательные поля,
// типы, enum'ы, диапазоны, minItems/maxItems, лишние ключи.
// Тест test/report/report_rules_test.dart сверяет эти правила со схемой,
// чтобы они не разошлись.

sealed class JsonRule {
  const JsonRule({this.nullable = false});

  /// Допускается ли null (в схеме — "type": [..., "null"]).
  final bool nullable;
}

class StringRule extends JsonRule {
  const StringRule({this.values, super.nullable});

  /// Допустимые значения (enum), без null. null — любая строка.
  final List<String>? values;
}

class IntRule extends JsonRule {
  const IntRule({this.min, this.max, super.nullable});

  final int? min;
  final int? max;
}

class ArrayRule extends JsonRule {
  const ArrayRule(this.items, {this.minItems, this.maxItems, super.nullable});

  final JsonRule items;
  final int? minItems;
  final int? maxItems;
}

/// Объект: все свойства обязательны, лишние запрещены
/// (так устроены все объекты схемы отчёта).
class ObjectRule extends JsonRule {
  const ObjectRule(this.properties, {super.nullable});

  final Map<String, JsonRule> properties;
}

const _verdict3 = ['good', 'partial', 'poor'];
const _verdict4 = ['good', 'partial', 'poor', 'not_visible'];
const componentIds = [
  'technique',
  'music',
  'partnership',
  'choreography_presentation',
];

const _personSummary = ObjectRule({
  'strengths': ArrayRule(StringRule()),
  'weaknesses': ArrayRule(StringRule()),
});

const _componentScore = ObjectRule({
  'couple': IntRule(min: 1, max: 10),
  'leader': IntRule(min: 1, max: 10, nullable: true),
  'follower': IntRule(min: 1, max: 10, nullable: true),
  'comment': StringRule(),
});

const reportRule = ObjectRule({
  'schema_version': StringRule(values: ['1.0']),
  'dance_id': StringRule(values: ['slow_waltz', 'quickstep', 'cha_cha', 'samba']),
  'video_assessment': ObjectRule({
    'status': StringRule(values: ['ok', 'low_confidence', 'unusable']),
    'quality': StringRule(values: ['good', 'acceptable', 'poor']),
    'couple_description': StringRule(),
    'music_source':
        StringRule(values: ['audio', 'analysis', 'audio_and_analysis', 'none']),
    'issues': ArrayRule(StringRule()),
  }),
  'figures': ArrayRule(ObjectRule({
    'figure_id': StringRule(nullable: true),
    'name_ru': StringRule(),
    'name_en': StringRule(nullable: true),
    'count': IntRule(min: 1),
    'quality': StringRule(values: _verdict3),
    'confidence': StringRule(values: ['high', 'medium', 'low']),
    'comment': StringRule(),
  })),
  'criteria_results': ArrayRule(ObjectRule({
    'criterion_id': StringRule(),
    'couple': StringRule(values: _verdict4),
    'leader': StringRule(values: _verdict4, nullable: true),
    'follower': StringRule(values: _verdict4, nullable: true),
    'comment': StringRule(),
  })),
  'errors': ArrayRule(
    ObjectRule({
      'severity': StringRule(values: ['critical', 'major', 'minor']),
      'who': StringRule(values: ['leader', 'follower', 'couple']),
      'component': StringRule(values: componentIds),
      'criterion_id': StringRule(nullable: true),
      'figure_id': StringRule(nullable: true),
      'description': StringRule(),
    }),
    maxItems: 25,
  ),
  'summary': ObjectRule({
    'overall_comment': StringRule(),
    'leader': _personSummary,
    'follower': _personSummary,
    'couple': _personSummary,
  }),
  'scores': ObjectRule({
    'technique': _componentScore,
    'music': _componentScore,
    'partnership': _componentScore,
    'choreography_presentation': _componentScore,
  }),
  'priorities': ArrayRule(StringRule(), minItems: 1, maxItems: 3),
  'additional_observations': ArrayRule(StringRule()),
});
