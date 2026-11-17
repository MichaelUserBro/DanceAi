import 'package:dance_ai/analysis/ai_provider.dart';
import 'package:dance_ai/analysis/cancel_token.dart';
import 'package:dance_ai/analysis/stub_ai_provider.dart';
import 'package:dance_ai/analysis/video_preparer.dart';
import 'package:dance_ai/report/report.dart';
import 'package:dance_ai/report/report_validator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_data.dart';

void main() {
  final data = loadTestAppData();
  final validator = ReportValidator(data.criteria);

  StubAiProvider stub(StubScenario s, {int seed = 1}) => StubAiProvider(
        catalog: data.criteria,
        scenario: s,
        minDelay: Duration.zero,
        maxDelay: Duration.zero,
        seed: seed,
      );

  AiRequest request(String danceId) => AiRequest(
        danceId: danceId,
        systemPrompt: 's',
        userPrompt: 'u',
        mode: SubmissionMode.frames,
        material: const PreparedMaterial(
          videoPath: 'v.mp4',
          durationSec: 10,
          frames: [],
          fps: 2,
          musicAnalysis: musicAnalysisUnavailable,
        ),
        reportSchema: data.reportSchema,
      );

  for (final dance in data.criteria.dances) {
    for (final status in ['ok', 'low_confidence', 'unusable']) {
      test('${dance.id} / $status: отчёт заглушки валиден (разные seed)', () {
        for (var seed = 0; seed < 25; seed++) {
          final json = stub(StubScenario.normal, seed: seed)
              .generateReport(dance, status: status);
          expect(validator.validate(json, dance: dance), isEmpty,
              reason: 'seed $seed');
          expect((json['video_assessment'] as Map)['status'], status);
          if (status != 'unusable') {
            expect((json['errors'] as List).length, inInclusiveRange(10, 15));
          }
        }
      });
    }
  }

  group('сценарии', () {
    final cases = {
      StubScenario.normal: VideoStatus.ok,
      StubScenario.lowConfidence: VideoStatus.lowConfidence,
      StubScenario.unusable: VideoStatus.unusable,
    };
    for (final e in cases.entries) {
      test('${e.key.id}: текст ответа проходит обработку', () async {
        final raw = (await stub(e.key)
            .analyze(request('samba'), onProgress: (_) {}, cancel: CancelToken())).text;
        final outcome = parseReport(raw,
            dance: data.criteria.dance('samba'), validator: validator);
        expect(outcome, isA<ParsedReport>());
        expect((outcome as ParsedReport).report.videoAssessment.status, e.value);
      });
    }

    test('invalid_json: ответ не проходит обработку', () async {
      final raw = (await stub(StubScenario.invalidJson)
          .analyze(request('quickstep'), onProgress: (_) {}, cancel: CancelToken())).text;
      expect(
          parseReport(raw,
              dance: data.criteria.dance('quickstep'), validator: validator),
          isA<InvalidReport>());
    });

    final errors = {
      StubScenario.invalidKey: AiErrorKind.invalidKey,
      StubScenario.rateLimit: AiErrorKind.rateLimit,
      StubScenario.network: AiErrorKind.network,
    };
    for (final e in errors.entries) {
      test('${e.key.id}: ошибка API', () {
        expect(
          stub(e.key).analyze(request('cha_cha'),
              onProgress: (_) {}, cancel: CancelToken()),
          throwsA(isA<AiException>().having((x) => x.kind, 'kind', e.value)),
        );
      });
    }

    test('отмена прерывает ожидание', () async {
      final slow = StubAiProvider(
          catalog: data.criteria, scenario: StubScenario.normal);
      final cancel = CancelToken();
      final future =
          slow.analyze(request('samba'), onProgress: (_) {}, cancel: cancel);
      cancel.cancel();
      await expectLater(future, throwsA(isA<AnalysisCancelled>()));
    });
  });

  group('личные оценки', () {
    List<Map<String, dynamic>> scoresOf(Map<String, dynamic> json) => [
          for (final v in (json['scores'] as Map).values)
            v as Map<String, dynamic>,
        ];

    test('обычно у обоих все 4 оценки, пропуски редки', () {
      final dance = data.criteria.dance('slow_waltz');
      var complete = 0;
      for (var seed = 0; seed < 200; seed++) {
        final s = scoresOf(stub(StubScenario.normal, seed: seed)
            .generateReport(dance, status: 'ok'));
        final nulls = s
            .where((x) => x['leader'] == null || x['follower'] == null)
            .length;
        expect(nulls, lessThanOrEqualTo(1));
        if (nulls == 0) complete++;
      }
      expect(complete, greaterThanOrEqualTo(160));
    });

    test('«Нет части личных оценок»: у партнёрши 1–2 пропуска, у партнёра — '
        'другой компонент; отчёт валиден', () async {
      for (var seed = 0; seed < 30; seed++) {
        final dance = data.criteria.dances[seed % data.criteria.dances.length];
        final raw = (await stub(StubScenario.partialScores, seed: seed)
            .analyze(request(dance.id), onProgress: (_) {}, cancel: CancelToken())).text;
        final outcome = parseReport(raw, dance: dance, validator: validator);
        expect(outcome, isA<ParsedReport>(), reason: 'seed $seed');
        final report = (outcome as ParsedReport).report;
        final noFollower = [
          for (final e in report.scores.entries)
            if (e.value.follower == null) e.key,
        ];
        final noLeader = [
          for (final e in report.scores.entries)
            if (e.value.leader == null) e.key,
        ];
        expect(noFollower.length, inInclusiveRange(1, 2));
        expect(noLeader, hasLength(1));
        expect(noFollower.toSet().intersection(noLeader.toSet()), isEmpty);
        expect(report.hasPersonScores(Who.follower), isTrue);
        expect(report.hasPersonScores(Who.leader), isTrue);
      }
    });
  });
}
