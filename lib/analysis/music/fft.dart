import 'dart:math' as math;
import 'dart:typed_data';

/// Быстрое преобразование Фурье (radix-2, на месте) для анализа музыки.
class Fft {
  Fft(this.size)
      : assert(size > 1 && (size & (size - 1)) == 0, 'size — степень двойки'),
        _cos = Float64List(size ~/ 2),
        _sin = Float64List(size ~/ 2),
        _rev = Int32List(size) {
    for (var i = 0; i < size ~/ 2; i++) {
      final a = -2 * math.pi * i / size;
      _cos[i] = math.cos(a);
      _sin[i] = math.sin(a);
    }
    final bits = size.bitLength - 1;
    for (var i = 0; i < size; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if (i & (1 << b) != 0) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
  }

  final int size;
  final Float64List _cos;
  final Float64List _sin;
  final Int32List _rev;

  /// Преобразует [re]/[im] (длины [size]) на месте.
  void transform(Float64List re, Float64List im) {
    for (var i = 0; i < size; i++) {
      final j = _rev[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (var len = 2; len <= size; len <<= 1) {
      final half = len >> 1;
      final step = size ~/ len;
      for (var start = 0; start < size; start += len) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step];
          final wi = _sin[k * step];
          final a = start + k;
          final b = a + half;
          final xr = re[b] * wr - im[b] * wi;
          final xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
        }
      }
    }
  }
}
