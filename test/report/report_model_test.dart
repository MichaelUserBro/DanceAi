import 'package:dance_ai/data/criteria.dart';
import 'package:dance_ai/data/providers_catalog.dart';
import 'package:dance_ai/report/overall_score.dart';
import 'package:dance_ai/report/report.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_data.dart';

void main() {
  final data = loadTestAppData();
  final componentIds = [for (final c in data.criteria.components) c.id];

  group('AppData', () {
    test('criteria: 4 танца, стили, music и полный список критериев', () {
      final c = data.criteria;
      expect(c.dances, hasLength(4));
      final waltz = c.dance('slow_waltz');
      expect(waltz.style, DanceStyle.standard);
      expect(c.dance('samba').style, DanceStyle.latin);
      expect(waltz.music.meter, '3/4');
      expect(waltz.music.beatsPerBar, 3);
      expect(waltz.music.tempoMinMpm, lessThanOrEqualTo(waltz.music.tempoMaxMpm));
      expect(c.criteriaFor(waltz).length,
          c.generalCriteria.length + waltz.criteria.length);
      expect(c.criterion(waltz, 'figure_execution')!.perPerson, isFalse);
      expect(waltz.figureById('whisk')!.nameEn, 'Whisk');
      expect(waltz.figureById('nope'), isNull);
    });

    test('providers: по алфавиту, «Свой» — последним', () {
      final names = [for (final p in data.providers.providers) p.name];
      final sorted = [...names]
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      expect(names, sorted);
      expect(data.providers.all.last.isCustom, isTrue);
      expect(data.providers.all.last.apiType, ApiType.openaiCompatible);
      expect(data.providers.byId('openrouter')!.apiType, ApiType.openaiCompatible);
    });

    test('схема отчёта читается', () {
      expect(data.reportSchema['title'], isNotEmpty);
      expect(data.reportSchemaText, contains('"criteria_results"'));
    });
  });

  group('DanceReport', () {
    final report = DanceReport.fromJson(loadExampleReportJson());

    test('разбирает пример целиком', () {
      expect(report.danceId, 'slow_waltz');
      expect(report.videoAssessment.status, VideoStatus.ok);
      expect(report.videoAssessment.musicSource, MusicSource.audioAndAnalysis);
      expect(report.figures.last.figureId, isNull);
      expect(report.criteriaResults, hasLength(13));
      final fe = report.criteriaResults
          .firstWhere((r) => r.criterionId == 'figure_execution');
      expect(fe.leader, isNull);
      expect(report.criteriaResults
          .firstWhere((r) => r.criterionId == 'steps_down_heel')
          .follower, Verdict.notVisible);
      expect(report.mistakes, hasLength(11));
      expect(report.scores.keys.toSet(), componentIds.toSet());
      expect(report.priorities, hasLength(3));
      expect(report.summary.of(Who.follower).strengths, isNotEmpty);
    });

    test('ключевые ошибки: только грубые, не больше 3', () {
      final key = report.keyMistakes;
      expect(key, hasLength(2));
      expect(key.every((m) => m.severity == Severity.critical), isTrue);
    });

    test('ключевые ошибки: если грубых нет — первые 3', () {
      final json = loadExampleReportJson();
      for (final e in json['errors'] as List) {
        (e as Map<String, dynamic>)['severity'] = 'minor';
      }
      final r = DanceReport.fromJson(json);
      expect(r.keyMistakes, hasLength(3));
      expect(r.keyMistakes.first.description, r.mistakes.first.description);
    });

    test('есть ли оценки партнёра и партнёрши', () {
      expect(report.hasPersonScores(Who.leader), isTrue);
      final json = loadExampleReportJson();
      for (final s in (json['scores'] as Map<String, dynamic>).values) {
        (s as Map<String, dynamic>)['follower'] = null;
      }
      expect(DanceReport.fromJson(json).hasPersonScores(Who.follower), isFalse);
    });
  });

  group('Общая оценка (spec 6)', () {
    test('пример: (4+5+4+5)/4 = 4,5', () {
      final report = DanceReport.fromJson(loadExampleReportJson());
      expect(overallScore(report, componentIds), 4.5);
    });

    test('округление до 0,1', () {
      expect(roundToTenth(17 / 4), 4.3); // 4,25 → 4,3
      expect(roundToTenth(19 / 4), 4.8); // 4,75 → 4,8
      expect(roundToTenth(16 / 4), 4.0);
      expect(roundToTenth(39 / 4), 9.8);
    });

    test('формат с запятой', () {
      expect(formatScore(4.3), '4,3');
      expect(formatScore(10), '10,0');
    });
  });
}
