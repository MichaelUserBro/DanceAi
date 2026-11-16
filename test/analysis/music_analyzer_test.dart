import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dance_ai/analysis/music/music_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../metronome.dart';

MusicHint hint(String meter, double minMpm, double maxMpm) => MusicHint(
  meter: meter,
  beatsPerBar: int.parse(meter.split('/').first),
  minMpm: minMpm,
  maxMpm: maxMpm,
);

double nearest(List<double> xs, double t) =>
    xs.map((x) => (x - t).abs()).reduce(math.min);

void expectGood(MusicAnalysis? r, Metronome m, {bool checkBars = true}) {
  expect(r, isNotNull);
  r!;
  expect(
    (r.bpm - m.bpm).abs(),
    lessThanOrEqualTo(2),
    reason: 'темп ${r.bpm} вместо ${m.bpm}',
  );
  for (final b in r.beats) {
    expect(
      nearest(m.beats, b),
      lessThanOrEqualTo(0.05),
      reason: 'доля $b не совпадает с метрономом',
    );
  }
  expect(r.beats.length, greaterThanOrEqualTo((m.beats.length * 0.9).floor()));
  if (checkBars) {
    for (final d in r.downbeats) {
      expect(
        nearest(m.downbeats, d),
        lessThanOrEqualTo(0.05),
        reason: 'такт начинается не с первой доли: $d',
      );
    }
  }
}

void main() {
  const analyzer = MusicAnalyzer();

  group('чистый метроном', () {
    test('3/4, 87 BPM (медленный вальс)', () {
      final m = Metronome(bpm: 87, meter: 3);
      expectGood(analyzer.analyze(m.render(), sr, hint('3/4', 28, 30)), m);
    });

    test('4/4, 124 BPM (ча-ча-ча)', () {
      final m = Metronome(bpm: 124, meter: 4);
      expectGood(analyzer.analyze(m.render(), sr, hint('4/4', 30, 32)), m);
    });

    test('4/4, 204 BPM (квикстеп)', () {
      final m = Metronome(bpm: 204, meter: 4);
      expectGood(analyzer.analyze(m.render(), sr, hint('4/4', 50, 52)), m);
    });

    test('2/4, 102 BPM (самба)', () {
      final m = Metronome(bpm: 102, meter: 2);
      expectGood(analyzer.analyze(m.render(), sr, hint('2/4', 50, 52)), m);
    });

    test('темп вне подсказки определяется по музыке: 3/4, 96 BPM', () {
      final m = Metronome(bpm: 96, meter: 3);
      expectGood(analyzer.analyze(m.render(), sr, hint('3/4', 28, 30)), m);
    });

    test('тишина до и после музыки — без лишних долей', () {
      final m = Metronome(bpm: 87, meter: 3, startSec: 4.2, endSec: 33);
      expectGood(analyzer.analyze(m.render(), sr, hint('3/4', 28, 30)), m);
    });
  });

  group('с шумом', () {
    for (final (bpm, meter, lo, hi) in [
      (87.0, 3, 28.0, 30.0),
      (124.0, 4, 30.0, 32.0),
      (204.0, 4, 50.0, 52.0),
      (102.0, 2, 50.0, 52.0),
    ]) {
      test('$meter/x, $bpm BPM', () {
        final m = Metronome(
          bpm: bpm,
          meter: meter,
          noise: 0.15,
          seed: bpm.toInt(),
        );
        final r = analyzer.analyze(m.render(), sr, hint('$meter/4', lo, hi));
        expectGood(r, m, checkBars: false);
      });
    }
  });

  group('анализ не удался', () {
    test('шум без ритма', () {
      final rnd = math.Random(7);
      final x = Float32List.fromList([
        for (var i = 0; i < sr * 30; i++) rnd.nextDouble() * 2 - 1,
      ]);
      expect(analyzer.analyze(x, sr, hint('3/4', 28, 30)), isNull);
    });

    test('тишина', () {
      expect(
        analyzer.analyze(Float32List(sr * 30), sr, hint('3/4', 28, 30)),
        isNull,
      );
    });

    test('слишком короткая запись', () {
      final m = Metronome(bpm: 120, meter: 4, durationSec: 5);
      expect(analyzer.analyze(m.render(), sr, hint('4/4', 30, 32)), isNull);
    });
  });

  test('текст по формату spec 7.6', () {
    final r = MusicAnalysis(
      bpm: 87.2,
      hint: hint('3/4', 28, 30),
      beats: const [0.42, 1.11, 1.8, 2.49],
      downbeats: const [0.42, 2.49],
      confidence: 0.8,
    );
    expect(
      r.toPromptText(),
      'Темп: 87 BPM (29 тактов/мин), размер 3/4.\n'
      'Начала тактов, с: 0.42, 2.49\n'
      'Доли, с: 0.42, 1.11, 1.80, 2.49\n'
      'Уверенность анализа: высокая.',
    );
  });

  group('запись из зала: ударные, шум толпы, аплодисменты, речь, '
      'тишина в начале', () {
    for (final (bpm, meter, lo, hi) in [
      (87.0, 3, 28.0, 30.0),
      (124.0, 4, 30.0, 32.0),
      (204.0, 4, 50.0, 52.0),
      (102.0, 2, 50.0, 52.0),
    ]) {
      test('$meter/x, $bpm BPM (3 варианта шума)', () {
        for (final seed in [bpm.toInt(), 21, 23]) {
          final rec = HallRecording(bpm: bpm, meter: meter, seed: seed);
          final r = analyzer.analyzeDetailed(
            rec.render(),
            sr,
            hint('$meter/4', lo, hi),
          );
          final a = r.analysis;
          expect(a, isNotNull, reason: r.failure);
          expect(
            (a!.bpm - bpm).abs(),
            lessThanOrEqualTo(2),
            reason: 'темп ${a.bpm}',
          );
          // Доли в музыке совпадают с настоящими (±70 мс) в большинстве.
          final inMusic = a.beats.where((b) => b >= rec.musicStartSec - 0.1);
          final hit = inMusic
              .where((b) => nearest(rec.beats, b) <= 0.07)
              .length;
          expect(hit / inMusic.length, greaterThanOrEqualTo(0.8));
          // До музыки долей почти нет (аплодисменты и речь — не ритм).
          expect(
            a.beats.where((b) => b < rec.musicStartSec - 1).length,
            lessThanOrEqualTo(1),
            reason: 'seed $seed',
          );
          expect(a.level, isNot(MusicConfidence.low), reason: 'seed $seed');
        }
      });
    }

    test('шум зала, аплодисменты и речь без музыки — ритм не найден', () {
      for (final seed in [9, 10, 11, 12, 13]) {
        final rec = HallRecording(
          bpm: 120,
          meter: 4,
          music: false,
          musicStartSec: 25,
          seed: seed,
        );
        final r = analyzer.analyzeDetailed(
          rec.render(),
          sr,
          hint('4/4', 30, 32),
        );
        expect(
          r.analysis,
          isNull,
          reason: 'seed $seed: нашёл ритм ${r.analysis?.bpm}',
        );
        expect(r.failure, isNotNull);
        expect(r.rmsDb, lessThan(-10));
      }
    });
  });

  test('уровень звука и причина неудачи для «Для разработчика»', () {
    final r = analyzer.analyzeDetailed(
      Float32List(sr * 20),
      sr,
      hint('3/4', 28, 30),
    );
    expect(r.analysis, isNull);
    expect(r.failure, 'тишина');
    expect(r.rmsDb, lessThan(-100));
  });
}
