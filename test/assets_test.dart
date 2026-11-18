// Проверка данных для ИИ: criteria.json, report.schema.json, промпты и пример отчёта.
// Полная проверка по JSON Schema здесь не делается — только правила из docs/spec.md, 7.7 п. 2.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

List<Map<String, dynamic>> _list(Object? value) =>
    (value as List).cast<Map<String, dynamic>>();

void main() {
  final criteria = _readJson('assets/criteria.json');
  final componentIds =
      _list(criteria['components']).map((c) => c['id'] as String).toSet();
  final generalCriteria = _list(criteria['general_criteria']);
  final dances = _list(criteria['dances']);

  Map<String, dynamic> danceById(String id) =>
      dances.firstWhere((d) => d['id'] == id);

  List<Map<String, dynamic>> allCriteriaOf(Map<String, dynamic> dance) => [
        ...generalCriteria,
        ..._list(dance['criteria']),
      ];

  group('criteria.json', () {
    test('4 компонента с ожидаемыми id', () {
      expect(componentIds, {
        'technique',
        'music',
        'partnership',
        'choreography_presentation',
      });
    });

    test('ровно 4 танца: slow_waltz, quickstep, cha_cha, samba', () {
      expect(dances.map((d) => d['id']).toList(),
          unorderedEquals(['slow_waltz', 'quickstep', 'cha_cha', 'samba']));
    });

    for (final dance in dances) {
      final id = dance['id'];

      test('$id: id критериев (общие + танца) уникальны', () {
        final ids = allCriteriaOf(dance).map((c) => c['id']).toList();
        expect(ids.toSet().length, ids.length, reason: 'дубли в $ids');
      });

      test('$id: id фигур уникальны', () {
        final ids = _list(dance['figures']).map((f) => f['id']).toList();
        expect(ids.toSet().length, ids.length, reason: 'дубли в $ids');
      });

      test('$id: component каждого критерия — id компонента', () {
        for (final c in allCriteriaOf(dance)) {
          expect(componentIds, contains(c['component']),
              reason: 'критерий ${c['id']}');
          expect(c['per_person'], isA<bool>(), reason: 'критерий ${c['id']}');
        }
      });

      test('$id: music — размер вида N/M и темп [min, max] в тактах/мин', () {
        final music = dance['music'] as Map<String, dynamic>;
        expect(music['meter'], matches(RegExp(r'^\d+/\d+$')));
        final tempo = (music['tempo_mpm'] as List).cast<int>();
        expect(tempo, hasLength(2));
        expect(tempo[0], greaterThan(0));
        expect(tempo[0], lessThanOrEqualTo(tempo[1]));
      });
    }

    test('удалённые фигуры tipli и chek отсутствуют', () {
      final allFigureIds = [
        for (final d in dances) ..._list(d['figures']).map((f) => f['id']),
      ];
      expect(allFigureIds, isNot(contains('tipli')));
      expect(allFigureIds, isNot(contains('chek')));
    });

    test('версия 1.3; «шассе», не «шоссе» (имена и примечания)', () {
      expect(criteria['version'], '1.3');
      final text = File('assets/criteria.json').readAsStringSync();
      expect(text.toLowerCase(), isNot(contains('шоссе')));
      expect(text, contains('Шассе (из променада)'));
      expect(text, contains('Типль шассе (типли)'));
    });

    test('спин и правый поворот: различие по пивоту в примечаниях', () {
      Map<String, dynamic> figure(String dance, String id) =>
          _list(danceById(dance)['figures']).firstWhere((f) => f['id'] == id);
      for (final d in ['slow_waltz', 'quickstep']) {
        final note = figure(d, 'natural_spin_turn')['note_ru'] as String;
        expect(note, contains('пивот назад'), reason: d);
        expect(note, contains('при редких кадрах'), reason: d);
      }
      expect(figure('slow_waltz', 'natural_turn')['note_ru'],
          contains('без пивота'));
    });
  });

  group('providers.json', () {
    final providersJson = _readJson('assets/providers.json');
    final providers = _list(providersJson['providers']);
    const apiTypes = {'anthropic', 'google', 'openai', 'openai_compatible'};

    test('id провайдеров уникальны, custom не пересекается с ними', () {
      final ids = providers.map((p) => p['id']).toList();
      expect(ids, isNotEmpty);
      expect(ids.toSet().length, ids.length, reason: 'дубли в $ids');
      final custom = providersJson['custom'] as Map<String, dynamic>;
      expect(ids, isNot(contains(custom['id'])));
      expect(custom['api_type'], 'openai_compatible');
      expect((custom['name'] as String).trim(), isNotEmpty);
    });

    for (final p in providers) {
      test('${p['id']}: обязательные поля заполнены, api_type допустим', () {
        expect(apiTypes, contains(p['api_type']));
        for (final key in ['name', 'base_url', 'key_url', 'free_note_ru']) {
          expect((p[key] as String).trim(), isNotEmpty, reason: key);
        }
        expect(Uri.parse(p['base_url'] as String).scheme, 'https');
        expect(Uri.parse(p['key_url'] as String).scheme, 'https');
        expect((p['key_steps_ru'] as List), isNotEmpty);
        expect(p['recommended_models'], isA<List>());
      });
    }
  });

  group('report.schema.json', () {
    test('читается как JSON, enum dance_id = id танцев из criteria.json', () {
      final schema = _readJson('assets/report.schema.json');
      final properties = schema['properties'] as Map<String, dynamic>;
      final danceEnum =
          (properties['dance_id'] as Map<String, dynamic>)['enum'] as List;
      expect(danceEnum,
          unorderedEquals(dances.map((d) => d['id'] as String).toList()));
    });
  });

  group('test/fixtures/report_example.json (spec 7.7 п. 2)', () {
    final report = _readJson('test/fixtures/report_example.json');
    final dance = danceById(report['dance_id'] as String);
    final danceCriteria = allCriteriaOf(dance);
    final criterionIds = danceCriteria.map((c) => c['id'] as String).toSet();
    final figureIds =
        _list(dance['figures']).map((f) => f['id'] as String).toSet();

    test('dance_id — существующий танец', () {
      expect(dances.map((d) => d['id']), contains(report['dance_id']));
    });

    test('criteria_results: каждый критерий танца ровно один раз, лишних нет',
        () {
      final ids = _list(report['criteria_results'])
          .map((r) => r['criterion_id'] as String)
          .toList();
      expect(ids.toSet().length, ids.length, reason: 'дубли в $ids');
      expect(ids.toSet(), criterionIds);
    });

    test('per_person: false → leader/follower null; true → не null', () {
      final perPerson = {
        for (final c in danceCriteria) c['id'] as String: c['per_person'],
      };
      for (final r in _list(report['criteria_results'])) {
        final id = r['criterion_id'];
        if (perPerson[id] == true) {
          expect(r['leader'], isNotNull, reason: '$id.leader');
          expect(r['follower'], isNotNull, reason: '$id.follower');
        } else {
          expect(r['leader'], isNull, reason: '$id.leader');
          expect(r['follower'], isNull, reason: '$id.follower');
        }
      }
    });

    test('figure_id в фигурах — null или id фигуры танца', () {
      for (final f in _list(report['figures'])) {
        final id = f['figure_id'];
        if (id != null) expect(figureIds, contains(id));
      }
    });

    test('criterion_id и figure_id в ошибках — null или id танца', () {
      for (final e in _list(report['errors'])) {
        final c = e['criterion_id'];
        final f = e['figure_id'];
        if (c != null) expect(criterionIds, contains(c));
        if (f != null) expect(figureIds, contains(f));
      }
    });

    test('scores: 4 компонента, все оценки — целые 1–10 (или null у людей)',
        () {
      final scores = report['scores'] as Map<String, dynamic>;
      expect(scores.keys.toSet(), componentIds);
      for (final entry in scores.entries) {
        final s = entry.value as Map<String, dynamic>;
        final couple = s['couple'];
        expect(couple, isA<int>(), reason: '${entry.key}.couple');
        expect(couple, inInclusiveRange(1, 10), reason: '${entry.key}.couple');
        for (final who in ['leader', 'follower']) {
          final v = s[who];
          if (v == null) continue;
          expect(v, isA<int>(), reason: '${entry.key}.$who');
          expect(v, inInclusiveRange(1, 10), reason: '${entry.key}.$who');
        }
      }
    });
  });

  group('assets/prompts', () {
    const files = [
      'analysis_system.md',
      'analysis_user.md',
      'input_video.md',
      'input_frames.md',
    ];

    for (final name in files) {
      test('$name существует и не пустой', () {
        final file = File('assets/prompts/$name');
        expect(file.existsSync(), isTrue);
        expect(file.readAsStringSync().trim(), isNotEmpty);
      });
    }

    test('analysis_user.md содержит все плейсхолдеры из spec 7.5', () {
      final text = File('assets/prompts/analysis_user.md').readAsStringSync();
      const placeholders = [
        '{{dance_id}}',
        '{{dance_name_ru}}',
        '{{dance_name_en}}',
        '{{input_description}}',
        '{{music_analysis}}',
        '{{components}}',
        '{{criteria}}',
        '{{figures}}',
        '{{report_schema}}',
      ];
      for (final p in placeholders) {
        expect(text, contains(p), reason: p);
      }
    });

    test('время моментов не запрашивается (ни в шаблонах, ни в схеме)', () {
      for (final path in [
        for (final name in files) 'assets/prompts/$name',
        'assets/report.schema.json',
      ]) {
        final text = File(path).readAsStringSync();
        expect(text, isNot(contains('м:сс от начала')), reason: path);
        expect(text, isNot(contains('момент м:сс')), reason: path);
      }
      final system =
          File('assets/prompts/analysis_system.md').readAsStringSync();
      expect(system, contains('Время (таймкоды, м:сс) не указывай.'));
      expect(system,
          contains('Время (таймкоды, м:сс, секунды) не указывай нигде в ответе'));
      // Метки времени кадров остаются — для сопоставления с музыкой.
      expect(File('assets/prompts/input_frames.md').readAsStringSync(),
          contains('t=12.50'));
    });

    test('музыка: слух важнее анализа; низкая уверенность — осторожно', () {
      final system =
          File('assets/prompts/analysis_system.md').readAsStringSync();
      expect(system, contains('верь своему слуху'));
      expect(system, contains('«Уверенность анализа: низкая»'));
      expect(system, contains('не ставь `confidence: "high"`'));
      expect(File('assets/prompts/input_video.md').readAsStringSync(),
          contains('Анализ музыки ниже — подсказка'));
    });
  });
}
