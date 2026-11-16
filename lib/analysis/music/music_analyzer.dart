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

/// Уверенность анализа музыки — пишется в текст для ИИ.
enum MusicConfidence {
  high('высокая'),
  medium('средняя'),
  low('низкая — темп и доли могут быть неточными');

  const MusicConfidence(this.labelRu);
  final String labelRu;
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

  /// Уверенность 0..1: выраженность периодичности и согласие темпа
  /// по разным частям записи.
  final double confidence;

  MusicConfidence get level => confidence >= MusicAnalyzer.highConfidence
      ? MusicConfidence.high
      : confidence >= MusicAnalyzer.mediumConfidence
      ? MusicConfidence.medium
      : MusicConfidence.low;

  double get mpm => bpm / hint.beatsPerBar;

  /// Текст по формату spec 7.6.
  String toPromptText() {
    String list(List<double> xs) =>
        xs.map((x) => x.toStringAsFixed(2)).join(', ');
    return 'Темп: ${bpm.round()} BPM (${mpm.round()} тактов/мин), '
        'размер ${hint.meter}.\n'
        'Начала тактов, с: ${list(downbeats)}\n'
        'Доли, с: ${list(beats)}\n'
        'Уверенность анализа: ${level.labelRu}.';
  }
}

/// Полный результат: анализ (или null) и сведения, почему он такой —
/// для «Для разработчика».
class MusicResult {
  const MusicResult({
    this.analysis,
    required this.rmsDb,
    required this.peakDb,
    this.periodicity,
    this.agreement,
    this.failure,
  });

  final MusicAnalysis? analysis;

  /// Уровень звука, dBFS (средний и пиковый).
  final double rmsDb;
  final double peakDb;

  /// Выраженность периодичности (автокорреляция огибающей), 0..1.
  final double? periodicity;

  /// Доля окон по 20 с, где темп совпал с общим, 0..1.
  final double? agreement;

  /// Почему анализ не удался (по-русски, для разработчика).
  final String? failure;
}

/// Анализ музыки на чистом Dart: огибающая начал звуков (спектральный поток)
/// → темп (автокорреляция + мягкая подсказка из criteria.json) → доли
/// (динамическое программирование, Ellis 2007) → начала тактов (акцент баса).
///
/// Рассчитан на реальную запись из зала: шум, аплодисменты, голос ведущего,
/// музыка не с первой секунды. «Ритм не найден» — только когда периодичности
/// нет; при сомнении — результат с низкой уверенностью.
///
/// Синхронный и тяжёлый — вызывать в отдельном изоляте.
class MusicAnalyzer {
  const MusicAnalyzer({this.log});

  /// Отладочный вывод по шагам (только для разработки).
  final void Function(String)? log;

  static const frameSize = 1024;
  static const hop = 256;
  static const minDurationSec = 8.0;
  static const minBpm = 40.0;
  static const maxBpm = 260.0;

  /// Ниже — периодичности нет (шум, тишина): у белого шума ~0,02,
  /// у музыки в шумном зале — от ~0,08.
  static const minPeriodicity = 0.045;

  /// При слабой периодичности темп должен совпасть хотя бы в стольких
  /// окнах — иначе это случайный пик, а не ритм.
  static const minAgreementWhenWeak = 0.75;
  static const weakPeriodicity = 0.12;

  /// Окно проверки согласия темпа.
  static const windowSec = 15.0;

  static const highConfidence = 0.7;
  static const mediumConfidence = 0.45;

  /// Ширина подсказки темпа, октавы: решает выбор между кратными темпами
  /// (×2, ÷2, ×3), но почти не влияет на темп рядом с ожидаемым.
  static const hintWidthOctaves = 0.5;

  /// null — анализ не удался (короткая запись, тишина, нет ритма).
  MusicAnalysis? analyze(Float32List samples, int sampleRate, MusicHint hint) =>
      analyzeDetailed(samples, sampleRate, hint).analysis;

  MusicResult analyzeDetailed(
    Float32List samples,
    int sampleRate,
    MusicHint hint,
  ) {
    var peak = 0.0;
    var sumSq = 0.0;
    for (final s in samples) {
      final a = s.abs();
      if (a > peak) peak = a;
      sumSq += s * s;
    }
    double db(double v) => v <= 1e-9 ? -180 : 20 * math.log(v) / math.ln10;
    final rmsDb = db(samples.isEmpty ? 0 : math.sqrt(sumSq / samples.length));
    final peakDb = db(peak);
    MusicResult fail(String why, {double? periodicity, double? agreement}) {
      log?.call('сдался: $why');
      return MusicResult(
        rmsDb: rmsDb,
        peakDb: peakDb,
        periodicity: periodicity,
        agreement: agreement,
        failure: why,
      );
    }

    if (samples.length < minDurationSec * sampleRate) {
      return fail('запись короче ${minDurationSec.round()} с');
    }
    if (peak < 1e-4) return fail('тишина');

    final env = _envelopes(samples, sampleRate, 1 / peak);
    final fr = sampleRate / hop; // кадров огибающей в секунду
    final onset = _normalize(_highPass(env.flux, (fr * 0.5).round()));
    final bass = _normalize(_highPass(env.bass, (fr * 0.5).round()));

    final tempo = _estimateTempo(onset, fr, hint);
    if (tempo == null) return fail('огибающая слишком короткая');
    final periodicity = tempo.confidence.clamp(0.0, 1.0).toDouble();
    final agreement = _agreement(onset, fr, hint, tempo.bpm);
    log?.call(
      'темп ${tempo.bpm.toStringAsFixed(1)}, периодичность '
      '${periodicity.toStringAsFixed(3)}, согласие окон '
      '${agreement?.toStringAsFixed(2) ?? '—'}',
    );
    if (periodicity < minPeriodicity) {
      return fail(
        'нет периодичности (${periodicity.toStringAsFixed(3)} < '
        '$minPeriodicity)',
        periodicity: periodicity,
        agreement: agreement,
      );
    }
    if (periodicity < weakPeriodicity &&
        agreement != null &&
        agreement < minAgreementWhenWeak) {
      return fail(
        'слабая периодичность и темп не совпадает по частям записи',
        periodicity: periodicity,
        agreement: agreement,
      );
    }

    final period = fr * 60 / tempo.bpm;
    var beatFrames = _trackBeats(onset, period);
    beatFrames = _trimQuiet(beatFrames, env.loudness, fr);
    beatFrames = _trimWeakEdges(beatFrames, onset);
    beatFrames = _trimAperiodicEdges(beatFrames, onset, period, fr);
    log?.call('долей после обрезки краёв: ${beatFrames.length}');
    if (beatFrames.length < 8) {
      return fail(
        'меньше 8 долей',
        periodicity: periodicity,
        agreement: agreement,
      );
    }

    double frameTime(int i) => (i * hop + frameSize / 2) / sampleRate;
    final beats = [for (final f in beatFrames) frameTime(f)];

    // Уточнённый темп по устойчивым интервалам между долями: срывы трекинга
    // (вступление, ведущий) не тянут темп.
    final bpm = _refinedBpm(beats) ?? tempo.bpm;

    final phase = _downbeatPhase(beatFrames, onset, bass, hint.beatsPerBar);
    final downbeats = [
      for (var i = phase; i < beats.length; i += hint.beatsPerBar) beats[i],
    ];

    // Уверенность: периодичность (0,3 и выше — полная) и согласие окон.
    final p = (periodicity / 0.3).clamp(0.0, 1.0);
    final confidence = agreement == null ? p : 0.5 * p + 0.5 * agreement;
    return MusicResult(
      analysis: MusicAnalysis(
        bpm: bpm,
        hint: hint,
        beats: beats,
        downbeats: downbeats,
        confidence: confidence,
      ),
      rmsDb: rmsDb,
      peakDb: peakDb,
      periodicity: periodicity,
      agreement: agreement,
    );
  }

  /// Доля окон по [windowSec] (шаг — половина окна), где темп совпал
  /// с общим в пределах 4 %. null — запись короче полутора окон.
  double? _agreement(
    Float64List onset,
    double fr,
    MusicHint hint,
    double globalBpm,
  ) {
    final win = (windowSec * fr).round();
    if (onset.length < win * 1.5) return null;
    var total = 0;
    var agree = 0;
    for (var start = 0; start + win <= onset.length; start += win ~/ 3) {
      final t = _estimateTempo(
        Float64List.sublistView(onset, start, start + win),
        fr,
        hint,
      );
      if (t == null) continue;
      total++;
      if ((t.bpm / globalBpm - 1).abs() < 0.04) agree++;
    }
    return total == 0 ? null : agree / total;
  }

  /// Темп по медиане устойчивых интервалов между долями
  /// (в пределах 10 % от медианы); среднее по ним.
  static double? _refinedBpm(List<double> beats) {
    if (beats.length < 4) return null;
    final ibi = [
      for (var i = 0; i + 1 < beats.length; i++) beats[i + 1] - beats[i],
    ];
    final sorted = [...ibi]..sort();
    final median = sorted[sorted.length ~/ 2];
    if (median <= 0) return null;
    var sumDt = 0.0;
    var count = 0;
    for (final d in ibi) {
      if ((d / median - 1).abs() < 0.1) {
        sumDt += d;
        count++;
      }
    }
    if (count < 3) return null;
    return 60 / (sumDt / count);
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

  /// Убирает крайние доли там, где ритма нет: аплодисменты, голос ведущего
  /// до музыки. Мера — локальная периодичность в окне 3 с: повторяется ли
  /// огибающая через период. Окно смотрит наружу от музыки (для начала —
  /// назад, для конца — вперёд), чтобы не захватывать саму музыку.
  static List<int> _trimAperiodicEdges(
    List<int> beats,
    Float64List onset,
    double period,
    double fr,
  ) {
    if (beats.length < 8) return beats;
    final span = (4 * fr).round();
    // Периодичность через долю и через две: в 2/4 и 4/4 удары на сильных
    // и слабых долях разные, и повтор чётче через две доли.
    double local(int f, int lag, {required bool leading}) {
      final a = math.max(0, leading ? f - span : f - lag);
      final b = math.min(onset.length - lag, leading ? f + 1 : f + span);
      if (b - a < lag) return 0;
      var mean = 0.0;
      for (var i = a; i < b + lag; i++) {
        mean += onset[i];
      }
      mean /= b + lag - a;
      var num = 0.0;
      var den = 0.0;
      for (var i = a; i < b; i++) {
        final x = onset[i] - mean;
        num += x * (onset[i + lag] - mean);
        den += x * x;
      }
      return den > 0 ? num / den : 0;
    }

    final lags = [period.round(), (2 * period).round()];
    double level(int f, {required bool leading}) => math.max(
      local(f, lags[0], leading: leading),
      local(f, lags[1], leading: leading),
    );
    final lead = [for (final b in beats) level(b, leading: true)];
    final trail = [for (final b in beats) level(b, leading: false)];
    double median(List<double> xs) => ([...xs]..sort())[xs.length ~/ 2];
    final leadThreshold = median(lead) * 0.45;
    final trailThreshold = median(trail) * 0.45;
    var start = 0;
    var end = beats.length;
    while (start < end && lead[start] < leadThreshold) {
      start++;
    }
    while (end > start && trail[end - 1] < trailThreshold) {
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

  // --- такты ---

  /// Какая из долей — первая в такте: максимум среднего акцента
  /// (бас + общий поток) по долям с этим номером.
  static int _downbeatPhase(
    List<int> beats,
    Float64List onset,
    Float64List bass,
    int meter,
  ) {
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
