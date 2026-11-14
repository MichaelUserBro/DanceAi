import 'dart:convert';

import 'package:dance_ai/report/report_validator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_data.dart';

void main() {
  final data = loadTestAppData();
  final validator = ReportValidator(data.criteria);
  final waltz = data.criteria.dance('slow_waltz');

  List<String> check(Map<String, dynamic> json) =>
      validator.validate(json, dance: waltz);

  Map<String, dynamic> criterion(Map<String, dynamic> json, String id) =>
      (json['criteria_results'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((r) => r['criterion_id'] == id);

  test('пример report_example.json проходит проверку', () {
    expect(check(loadExampleReportJson()), isEmpty);
  });

  group('испорченные варианты не проходят', () {
    void expectProblem(void Function(Map<String, dynamic>) spoil, String part) {
      final json = loadExampleReportJson();
      spoil(json);
      final problems = check(json);
      expect(problems, isNotEmpty);
      expect(problems.join('\n'), contains(part));
    }

    test('пропущенный критерий', () => expectProblem(
        (j) => (j['criteria_results'] as List)
            .removeWhere((r) => r['criterion_id'] == 'swing'),
        'swing'));

    test('лишний критерий', () => expectProblem(
        (j) => (j['criteria_results'] as List).add({
              'criterion_id': 'bounce_action',
              'couple': 'good',
              'leader': 'good',
              'follower': 'good',
              'comment': 'x',
            }),
        'bounce_action'));

    test('критерий дважды', () => expectProblem(
        (j) => (j['criteria_results'] as List)
            .add(Map<String, dynamic>.from(criterion(j, 'swing'))),
        'встречается 2 раза'));

    test('чужой figure_id в фигурах', () => expectProblem(
        (j) => ((j['figures'] as List).first as Map)['figure_id'] = 'voltas',
        'voltas'));

    test('чужой figure_id в ошибках', () => expectProblem(
        (j) => ((j['errors'] as List).first as Map)['figure_id'] = 'hip_twist',
        'hip_twist'));

    test('чужой criterion_id в ошибках', () => expectProblem(
        (j) => ((j['errors'] as List).first as Map)['criterion_id'] = 'sharpness',
        'sharpness'));

    test('per_person: false, но leader заполнен', () => expectProblem(
        (j) => criterion(j, 'figure_execution')['leader'] = 'good',
        'figure_execution'));

    test('per_person: true, но follower = null', () => expectProblem(
        (j) => criterion(j, 'swing')['follower'] = null,
        'swing'));

    test('оценка 11', () => expectProblem(
        (j) => ((j['scores'] as Map)['music'] as Map)['couple'] = 11,
        'вне диапазона'));

    test('оценка 0 у партнёра', () => expectProblem(
        (j) => ((j['scores'] as Map)['music'] as Map)['leader'] = 0,
        'вне диапазона'));

    test('дробная оценка', () => expectProblem(
        (j) => ((j['scores'] as Map)['music'] as Map)['couple'] = 5.5,
        'целое'));

    test('другой dance_id', () => expectProblem(
        (j) => j['dance_id'] = 'samba', 'dance_id'));

    test('неизвестный verdict', () => expectProblem(
        (j) => criterion(j, 'swing')['couple'] = 'excellent', 'excellent'));

    test('лишнее поле', () => expectProblem(
        (j) => j['overall_score'] = 7, 'overall_score'));

    test('нет обязательного поля', () => expectProblem(
        (j) => j.remove('summary'), 'summary'));

    test('пустые priorities', () => expectProblem(
        (j) => j['priorities'] = <String>[], 'не меньше 1'));

    test('not_visible в качестве фигуры', () => expectProblem(
        (j) => ((j['figures'] as List).first as Map)['quality'] = 'not_visible',
        'not_visible'));
  });

  group('разбор текста ответа', () {
    final text = jsonEncode(loadExampleReportJson());

    test('чистый JSON', () {
      expect(parseReport(text, dance: waltz, validator: validator),
          isA<ParsedReport>());
    });

    test('обёртка ```json', () {
      expect(
          parseReport('```json\n$text\n```', dance: waltz, validator: validator),
          isA<ParsedReport>());
      expect(stripCodeFence('```\n{"a":1}\n```'), '{"a":1}');
    });

    test('текст вокруг объекта', () {
      expect(
          parseReport('Вот отчёт:\n$text\nГотово.',
              dance: waltz, validator: validator),
          isA<ParsedReport>());
    });

    test('не JSON', () {
      final r = parseReport('Не могу оценить', dance: waltz, validator: validator);
      expect(r, isA<InvalidReport>());
      expect((r as InvalidReport).notJson, isTrue);
    });

    test('массив вместо объекта', () {
      expect(parseReport('[1,2]', dance: waltz, validator: validator),
          isA<InvalidReport>());
    });
  });
}
