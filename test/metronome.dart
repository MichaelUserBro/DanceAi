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

