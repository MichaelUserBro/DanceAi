import 'dart:math' as math;
import 'dart:typed_data';

const sr = 22050;

/// Синтетический метроном: щелчок на каждую долю; на первой доле такта —
/// громче и с басом (как бочка на «раз»).
class Metronome {
  Metronome({
    required this.bpm,
    required this.meter,
    this.durationSec = 40,
    this.startSec = 0.37,
    this.endSec,
    this.noise = 0,
    this.seed = 1,
  });

  final double bpm;
  final int meter;
  final double durationSec;
  final double startSec;
  final double? endSec;
  final double noise;
  final int seed;

  late final List<double> beats = [
    for (var t = startSec; t < (endSec ?? durationSec) - 0.1; t += 60 / bpm) t,
  ];
  late final List<double> downbeats = [
    for (var i = 0; i < beats.length; i += meter) beats[i],
  ];

  Float32List render() {
    final n = (durationSec * sr).round();
    final x = Float32List(n);
    final rnd = math.Random(seed);
    if (noise > 0) {
      for (var i = 0; i < n; i++) {
        x[i] = (rnd.nextDouble() * 2 - 1) * noise;
      }
    }
    for (var b = 0; b < beats.length; b++) {
      final down = b % meter == 0;
      final start = (beats[b] * sr).round();
      final len = (0.06 * sr).round();
      for (var i = 0; i < len && start + i < n; i++) {
        final t = i / sr;
        final decay = math.exp(-t * 60);
        var v = (down ? 0.6 : 0.35) * math.sin(2 * math.pi * 1500 * t) * decay;
        if (down) {
          v += 0.8 * math.sin(2 * math.pi * 90 * t) * math.exp(-t * 30);
        }
        x[start + i] += v;
      }
    }
    return x;
  }
}

/// Запись «из зала»: музыка с ударными, басом и аккордами + шум толпы,
/// аплодисменты, голос ведущего, тишина в начале. Ближе к реальности, чем
/// метроном: удары не единственный источник начал звуков.
class HallRecording {
  HallRecording({
    required this.bpm,
    required this.meter,
    this.durationSec = 50,
    this.musicStartSec = 6,
    this.crowd = 0.04,
    this.applause = true,
    this.speech = true,
    this.music = true,
    this.seed = 1,
  });

  final double bpm;
  final int meter;
  final double durationSec;
  final double musicStartSec;
  final double crowd;
  final bool applause;
  final bool speech;
  final bool music;
  final int seed;

  late final List<double> beats = music
      ? [for (var t = musicStartSec; t < durationSec - 0.2; t += 60 / bpm) t]
      : const [];

  Float32List render() {
    final n = (durationSec * sr).round();
    final x = Float32List(n);
    final r = math.Random(seed);
    void add(int at, double v) {
      if (at >= 0 && at < n) x[at] += v;
    }

    // Шум зала: «розоватый» шум (сглаженный белый), всё время.
    var lp = 0.0;
    for (var i = 0; i < n; i++) {
      lp = 0.97 * lp + 0.03 * (r.nextDouble() * 2 - 1);
      x[i] += crowd * (lp * 6 + 0.3 * (r.nextDouble() * 2 - 1));
    }
    // Аплодисменты: плотные случайные хлопки до музыки и в конце.
    if (applause) {
      for (final (from, to) in [
        (1.0, musicStartSec - 1),
        (durationSec - 4, durationSec),
      ]) {
        for (var t = from; t < to; t += 0.004 + r.nextDouble() * 0.02) {
          final at = (t * sr).round();
          final a = 0.05 + r.nextDouble() * 0.1;
          for (var k = 0; k < 120; k++) {
            add(at + k, a * (r.nextDouble() * 2 - 1) * math.exp(-k / 25));
          }
        }
      }
    }
    // Голос ведущего: слоги случайной длины 80–300 мс, паузы, основной тон
    // 110–220 Гц с гармониками; до музыки и поверх неё в середине.
    if (speech) {
      for (final (from, to) in [
        (0.5, musicStartSec),
        (durationSec * 0.45, durationSec * 0.45 + 5),
      ]) {
        var t = from;
        while (t < to) {
          final len = 0.08 + r.nextDouble() * 0.22;
          final f0 = 110 + r.nextDouble() * 110;
          final amp = 0.1 + r.nextDouble() * 0.12;
          final start = (t * sr).round();
          final m = (len * sr).round();
          for (var k = 0; k < m; k++) {
            final env = math.sin(math.pi * k / m);
            var v = 0.0;
            for (var h = 1; h <= 5; h++) {
              v += math.sin(2 * math.pi * f0 * h * k / sr) / h;
            }
            add(start + k, amp * env * v);
          }
          t +=
              len + (r.nextDouble() < 0.25 ? 0.2 + r.nextDouble() * 0.5 : 0.02);
        }
      }
    }
    if (!music) return x;

    final beatSec = 60 / bpm;
    for (var b = 0; b < beats.length; b++) {
      final at = (beats[b] * sr).round();
      final pos = b % meter;
      // Бочка — на первую долю (и на третью в 4/4).
      if (pos == 0 || (meter == 4 && pos == 2)) {
        for (var k = 0; k < (0.25 * sr); k++) {
          final t = k / sr;
          add(
            at + k,
            0.5 *
                math.sin(2 * math.pi * (50 + 60 * math.exp(-t * 30)) * t) *
                math.exp(-t * 12),
          );
        }
      }
      // Малый барабан — на слабые доли.
      if (pos != 0) {
        for (var k = 0; k < (0.12 * sr); k++) {
          add(at + k, 0.18 * (r.nextDouble() * 2 - 1) * math.exp(-k / sr * 30));
        }
      }
      // Хай-хэт — восьмыми.
      for (final off in [0.0, 0.5]) {
        final h = at + (off * beatSec * sr).round();
        for (var k = 0; k < 400; k++) {
          add(h, 0);
          add(h + k, 0.05 * (r.nextDouble() * 2 - 1) * math.exp(-k / 60));
        }
      }
      // Бас: нота на долю, тянется почти до следующей.
      final f = [55.0, 65.4, 73.4, 82.4][(b ~/ meter) % 4];
      final m = (beatSec * 0.9 * sr).round();
      for (var k = 0; k < m; k++) {
        add(
          at + k,
          0.12 *
              math.sin(2 * math.pi * f * k / sr) *
              math.min(1, k / 200) *
              (1 - k / m),
        );
      }
    }
    // Аккорды: тянутся весь такт, смена на первой доле.
    for (var b = 0; b < beats.length; b += meter) {
      final at = (beats[b] * sr).round();
      final m = (meter * beatSec * sr).round();
      final root = [220.0, 261.6, 293.7, 196.0][(b ~/ meter) % 4];
      for (var k = 0; k < m; k++) {
        var v = 0.0;
        for (final ratio in [1.0, 1.26, 1.5]) {
          v += math.sin(2 * math.pi * root * ratio * k / sr);
        }
        add(at + k, 0.03 * v * math.min(1, k / 2000));
      }
    }
    return x;
  }
}
