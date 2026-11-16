import 'dart:math' as math;
import 'dart:typed_data';

import '../../data/criteria.dart';
import 'fft.dart';

/// Подсказка из criteria.json (`music.meter`, `music.tempo_mpm`).
/// Темп — подсказка, а не жёсткое ограничение (spec 7.4).
class MusicHint {
  const MusicHint({
    required this.meter,
    required this.beatsPerBar,
    required this.minMpm,
    required this.maxMpm,
  });

  factory MusicHint.fromDance(DanceMusic music) => MusicHint(
        meter: music.meter,
        beatsPerBar: music.beatsPerBar,
        minMpm: music.tempoMinMpm.toDouble(),
        maxMpm: music.tempoMaxMpm.toDouble(),
      );

  final String meter;
  final int beatsPerBar;
  final double minMpm;
  final double maxMpm;

  /// Ожидаемый темп в долях в минуту.
  double get expectedBpm => (minMpm + maxMpm) / 2 * beatsPerBar;
}

class MusicAnalysis {
  const MusicAnalysis({
    required this.bpm,
    required this.hint,
    required this.beats,
    required this.downbeats,
    required this.confidence,
  });

  final double bpm;
  final MusicHint hint;

  /// Доли и начала тактов, с от начала видео.
  final List<double> beats;
  final List<double> downbeats;

  /// Выраженность периодичности, 0..1 (для «Для разработчика»).
  final double confidence;

  double get mpm => bpm / hint.beatsPerBar;

  /// Текст по формату spec 7.6.
  String toPromptText() {
    String list(List<double> xs) =>
        xs.map((x) => x.toStringAsFixed(2)).join(', ');
    return 'Темп: ${bpm.round()} BPM (${mpm.round()} тактов/мин), '
        'размер ${hint.meter}.\n'
        'Начала тактов, с: ${list(downbeats)}\n'
        'Доли, с: ${list(beats)}';
  }
}

/// Анализ музыки на чистом Dart: огибающая начал звуков (спектральный поток)
/// → темп (автокорреляция + мягкая подсказка из criteria.json) → доли
/// (динамическое программирование, Ellis 2007) → начала тактов (акцент баса).
///
/// Синхронный и тяжёлый — вызывать в отдельном изоляте.
class MusicAnalyzer {
  const MusicAnalyzer();

  static const frameSize = 1024;
  static const hop = 256;
  static const minDurationSec = 8.0;
  static const minBpm = 40.0;
  static const maxBpm = 260.0;

  /// Ниже этого запись считается непериодичной (шум, речь, тишина).
  static const minConfidence = 0.12;

  /// Ширина подсказки темпа, октавы: решает выбор между кратными темпами
  /// (×2, ÷2, ×3), но почти не влияет на темп рядом с ожидаемым.
  static const hintWidthOctaves = 0.5;

  /// null — анализ не удался (короткая запись, тишина, нет ритма).
  MusicAnalysis? analyze(Float32List samples, int sampleRate, MusicHint hint) {
    if (samples.length < minDurationSec * sampleRate) return null;
    var peak = 0.0;
    for (final s in samples) {
      final a = s.abs();
      if (a > peak) peak = a;
    }
    if (peak < 1e-4) return null;

    final env = _envelopes(samples, sampleRate, 1 / peak);
    final fr = sampleRate / hop; // кадров огибающей в секунду
    final onset = _normalize(_highPass(env.flux, (fr * 0.5).round()));
    final bass = _normalize(_highPass(env.bass, (fr * 0.5).round()));

    final tempo = _estimateTempo(onset, fr, hint);
    if (tempo == null || tempo.confidence < minConfidence) return null;

    final period = fr * 60 / tempo.bpm;
    var beatFrames = _trackBeats(onset, period);
    beatFrames = _trimQuiet(beatFrames, env.loudness, fr);
    beatFrames = _trimWeakEdges(beatFrames, onset);
    if (beatFrames.length < 8) return null;

    double frameTime(int i) => (i * hop + frameSize / 2) / sampleRate;
    final beats = [for (final f in beatFrames) frameTime(f)];

    // Уточнённый темп: наклон прямой «номер доли → время».
    final slope = _slope(beats);
    final bpm = slope > 0 ? 60 / slope : tempo.bpm;

    final phase = _downbeatPhase(beatFrames, onset, bass, hint.beatsPerBar);
    final downbeats = [
      for (var i = phase; i < beats.length; i += hint.beatsPerBar) beats[i],
    ];

    return MusicAnalysis(
      bpm: bpm,
      hint: hint,
      beats: beats,
      downbeats: downbeats,
      confidence: tempo.confidence.clamp(0, 1).toDouble(),
    );
  }

  // --- огибающие ---

  _Envelopes _envelopes(Float32List x, int sr, double gain) {
    final n = (x.length - frameSize) ~/ hop + 1;
    final fft = Fft(frameSize);
    final window = Float64List(frameSize);
    for (var i = 0; i < frameSize; i++) {
      window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / frameSize);
    }
    final bins = frameSize ~/ 2;
    final bassBins = (200 * frameSize / sr).ceil().clamp(2, bins);
    final re = Float64List(frameSize);
    final im = Float64List(frameSize);
    var prev = Float64List(bins + 1);
    var cur = Float64List(bins + 1);
    final flux = Float64List(n);
    final bass = Float64List(n);
    final loud = Float64List(n);
    for (var f = 0; f < n; f++) {
      final start = f * hop;
      var energy = 0.0;
      for (var i = 0; i < frameSize; i++) {
        final v = x[start + i] * gain;
        energy += v * v;
        re[i] = v * window[i];
        im[i] = 0;
      }
      loud[f] = energy / frameSize;
      fft.transform(re, im);
      var sumAll = 0.0;
      var sumBass = 0.0;
      for (var k = 1; k <= bins; k++) {
        final mag = math.sqrt(re[k] * re[k] + im[k] * im[k]);
        final l = math.log(1 + 100 * mag);
        cur[k] = l;
        if (f > 0) {
          final d = l - prev[k];
          if (d > 0) {
            sumAll += d;
            if (k <= bassBins) sumBass += d;
          }
        }
      }
      flux[f] = sumAll;
      bass[f] = sumBass;
      final t = prev;
      prev = cur;
      cur = t;
    }
    return _Envelopes(flux, bass, loud);
  }

  /// Вычитает скользящее среднее (±[half] кадров) и обрезает отрицательное.
  static Float64List _highPass(Float64List x, int half) {
    final n = x.length;
    final prefix = Float64List(n + 1);
    for (var i = 0; i < n; i++) {
      prefix[i + 1] = prefix[i] + x[i];
    }
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      final a = math.max(0, i - half);
      final b = math.min(n, i + half + 1);
      final mean = (prefix[b] - prefix[a]) / (b - a);
      final v = x[i] - mean;
      out[i] = v > 0 ? v : 0;
    }
    return out;
  }

  static Float64List _normalize(Float64List x) {
    if (x.isEmpty) return x;
    var mean = 0.0;
    for (final v in x) {
      mean += v;
    }
    mean /= x.length;
    var variance = 0.0;
    for (final v in x) {
      variance += (v - mean) * (v - mean);
    }
    final std = math.sqrt(variance / x.length);
    if (std < 1e-12) return Float64List(x.length);
    return Float64List.fromList([for (final v in x) v / std]);
  }

  // --- темп ---

  _Tempo? _estimateTempo(Float64List o, double fr, MusicHint hint) {
    const multiples = 4;
    final n = o.length;
    final maxLag = (multiples * fr * 60 / minBpm).ceil() + 2;
    if (n < maxLag * 2) return null;
    var mean = 0.0;
    for (final v in o) {
      mean += v;
    }
    mean /= n;
    final c = Float64List(n);
    for (var i = 0; i < n; i++) {
      c[i] = o[i] - mean;
    }
    final acf = Float64List(maxLag + 1);
    for (var lag = 0; lag <= maxLag; lag++) {
      var s = 0.0;
      for (var i = lag; i < n; i++) {
        s += c[i] * c[i - lag];
      }
      acf[lag] = s / (n - lag);
    }
    if (acf[0] <= 0) return null;

    double at(double lag) {
      final i = lag.floor();
      if (i + 1 > maxLag) return 0;
      final f = lag - i;
      return acf[i] * (1 - f) + acf[i + 1] * f;
    }

    double rawScore(double bpm) {
      final lag = fr * 60 / bpm;
      var s = 0.0;
      for (var m = 1; m <= multiples; m++) {
        s += at(lag * m);
      }
      return s / multiples / acf[0];
    }

    final center = hint.expectedBpm;
    var bestBpm = 0.0;
    var best = double.negativeInfinity;
    for (var bpm = minBpm; bpm <= maxBpm; bpm += 0.1) {
      final raw = rawScore(bpm);
      final d = math.log(bpm / center) / math.ln2 / hintWidthOctaves;
      final weighted = raw * math.exp(-0.5 * d * d);
      if (weighted > best) {
        best = weighted;
        bestBpm = bpm;
      }
    }
    if (bestBpm == 0) return null;
    return _Tempo(bestBpm, rawScore(bestBpm));
  }

  // --- доли ---

  /// Трекинг долей динамическим программированием (Ellis 2007).
  static List<int> _trackBeats(Float64List o, double period) {
    const tightness = 100.0;
    final n = o.length;
    final score = Float64List(n);
    final back = Int32List(n)..fillRange(0, n, -1);
    final minBack = (period / 2).round();
    final maxBack = (period * 2).round();
    for (var t = 0; t < n; t++) {
      var best = 0.0;
      var arg = -1;
      for (var tau = t - maxBack; tau <= t - minBack; tau++) {
        if (tau < 0) continue;
        final r = math.log((t - tau) / period);
        final v = score[tau] - tightness * r * r;
        if (arg < 0 || v > best) {
          best = v;
          arg = tau;
        }
      }
      score[t] = o[t] + (arg >= 0 && best > 0 ? best : 0);
      back[t] = arg >= 0 && best > 0 ? arg : -1;
    }
    // Последняя доля — максимум в последнем периоде.
    var last = math.max(0, n - period.round());
    for (var t = last; t < n; t++) {
      if (score[t] > score[last]) last = t;
    }
    final beats = <int>[];
    for (var t = last; t >= 0; t = back[t]) {
      beats.add(t);
    }
    return beats.reversed.toList();
  }

  /// Убирает доли в тихом начале и конце (до и после музыки).
  static List<int> _trimQuiet(List<int> beats, Float64List loud, double fr) {
    if (beats.isEmpty) return beats;
    final half = (fr * 0.5).round();
    final prefix = Float64List(loud.length + 1);
    for (var i = 0; i < loud.length; i++) {
      prefix[i + 1] = prefix[i] + loud[i];
    }
    double local(int f) {
      final a = math.max(0, f - half);
      final b = math.min(loud.length, f + half + 1);
      return (prefix[b] - prefix[a]) / (b - a);
    }

    final levels = [for (final b in beats) local(b)];
    final sorted = [...levels]..sort();
    final median = sorted[sorted.length ~/ 2];
    final threshold = median * 0.01; // −20 дБ от типичной громкости
    var start = 0;
    var end = beats.length;
    while (start < end && levels[start] < threshold) {
      start++;
    }
    while (end > start && levels[end - 1] < threshold) {
      end--;
    }
    return beats.sublist(start, end);
  }

  /// Убирает крайние доли без удара: трекер продолжает сетку долей
  /// в шум до первого и после последнего удара. Порог — посередине между
  /// типичной силой на долях и между долями (фон).
  static List<int> _trimWeakEdges(List<int> beats, Float64List onset) {
    if (beats.length < 3) return beats;
    double median(List<double> xs) => ([...xs]..sort())[xs.length ~/ 2];
    final strength = [for (final b in beats) _peakNear(onset, b)];
    final between = [
      for (var i = 0; i + 1 < beats.length; i++)
        _peakNear(onset, (beats[i] + beats[i + 1]) ~/ 2),
    ];
    final onBeat = median(strength);
    final background = median(between);
    if (onBeat <= background) return beats;
    final threshold = (onBeat + background) / 2;
    var start = 0;
    var end = beats.length;
    while (start < end && strength[start] < threshold) {
      start++;
    }
    while (end > start && strength[end - 1] < threshold) {
      end--;
    }
    return beats.sublist(start, end);
  }

  static double _peakNear(Float64List x, int f) {
    var m = 0.0;
    for (var i = math.max(0, f - 2); i <= math.min(x.length - 1, f + 2); i++) {
      if (x[i] > m) m = x[i];
    }
    return m;
  }

  static double _slope(List<double> ys) {
    final n = ys.length;
    final mx = (n - 1) / 2;
    var my = 0.0;
    for (final y in ys) {
      my += y;
    }
    my /= n;
    var num = 0.0;
    var den = 0.0;
    for (var i = 0; i < n; i++) {
      num += (i - mx) * (ys[i] - my);
      den += (i - mx) * (i - mx);
    }
    return den == 0 ? 0 : num / den;
  }

  // --- такты ---

  /// Какая из долей — первая в такте: максимум среднего акцента
  /// (бас + общий поток) по долям с этим номером.
  static int _downbeatPhase(
      List<int> beats, Float64List onset, Float64List bass, int meter) {
    if (meter <= 1) return 0;
    final o = [for (final b in beats) _peakNear(onset, b)];
    final s = [for (final b in beats) _peakNear(bass, b)];
    double mean(List<double> xs) =>
        xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;
    final mo = mean(o);
    final ms = mean(s);
    var bestPhase = 0;
    var best = double.negativeInfinity;
    for (var p = 0; p < meter && p < beats.length; p++) {
      var sum = 0.0;
      var count = 0;
      for (var i = p; i < beats.length; i += meter) {
        sum += (ms > 0 ? s[i] / ms : 0) + (mo > 0 ? o[i] / mo : 0);
        count++;
      }
      final v = sum / count;
      if (v > best) {
        best = v;
        bestPhase = p;
      }
    }
    return bestPhase;
  }
}

class _Envelopes {
  const _Envelopes(this.flux, this.bass, this.loudness);
  final Float64List flux;
  final Float64List bass;
  final Float64List loudness;
}

class _Tempo {
  const _Tempo(this.bpm, this.confidence);
  final double bpm;
  final double confidence;
}
