// Сверка правил валидатора (lib/report/report_rules.dart) с
// assets/report.schema.json: типы, null, enum'ы, диапазоны, minItems/maxItems,
// обязательные поля и запрет лишних. Если схему поменяли — тест упадёт.

import 'package:dance_ai/report/report_rules.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_data.dart';

void main() {
  final schema = loadTestAppData().reportSchema;
  final defs = schema[r'$defs'] as Map<String, dynamic>;

  Map<String, dynamic> resolve(Map<String, dynamic> node) {
    final ref = node[r'$ref'] as String?;
    if (ref == null) return node;
    const prefix = r'#/$defs/';
    expect(ref, startsWith(prefix));
    return resolve(defs[ref.substring(prefix.length)] as Map<String, dynamic>);
  }

  void compare(Map<String, dynamic> rawNode, JsonRule rule, String path) {
    final node = resolve(rawNode);
    final types = switch (node['type']) {
      final String t => [t],
      final List<dynamic> l => l.cast<String>(),
      _ => fail('$path: в схеме нет type'),
    };
    final baseTypes = types.where((t) => t != 'null').toList();
    expect(baseTypes, hasLength(1), reason: '$path: ожидается один тип');
    expect(rule.nullable, types.contains('null'), reason: '$path: nullable');

    final schemaEnum =
        (node['enum'] as List?)?.where((v) => v != null).cast<String>().toList();

    switch (rule) {
      case StringRule(:final values):
        expect(baseTypes.single, 'string', reason: path);
        if (schemaEnum == null) {
          expect(values, isNull, reason: '$path: в схеме нет enum');
        } else {
          expect(values, isNotNull, reason: '$path: в схеме есть enum');
          expect(values!.toSet(), schemaEnum.toSet(), reason: '$path: enum');
          expect(values.length, schemaEnum.length, reason: '$path: дубли enum');
        }
      case IntRule(:final min, :final max):
        expect(baseTypes.single, 'integer', reason: path);
        expect(min, node['minimum'], reason: '$path: minimum');
        expect(max, node['maximum'], reason: '$path: maximum');
        expect(schemaEnum, isNull, reason: path);
      case ArrayRule(:final items, :final minItems, :final maxItems):
        expect(baseTypes.single, 'array', reason: path);
        expect(minItems, node['minItems'], reason: '$path: minItems');
        expect(maxItems, node['maxItems'], reason: '$path: maxItems');
        compare(node['items'] as Map<String, dynamic>, items, '$path[]');
      case ObjectRule(:final properties):
        expect(baseTypes.single, 'object', reason: path);
        expect(node['additionalProperties'], isFalse,
            reason: '$path: additionalProperties');
        final schemaProps = node['properties'] as Map<String, dynamic>;
        expect(properties.keys.toSet(), schemaProps.keys.toSet(),
            reason: '$path: набор полей');
        expect((node['required'] as List).toSet(), schemaProps.keys.toSet(),
            reason: '$path: все поля обязательны (на это рассчитан валидатор)');
        for (final e in properties.entries) {
          compare(schemaProps[e.key] as Map<String, dynamic>, e.value,
              '$path.${e.key}');
        }
    }
  }

  test('правила валидатора совпадают с report.schema.json', () {
    compare(schema, reportRule, r'$');
  });

  test('компоненты в правилах = компоненты criteria.json', () {
    final ids = [for (final c in loadTestAppData().criteria.components) c.id];
    expect(componentIds.toSet(), ids.toSet());
  });
}
