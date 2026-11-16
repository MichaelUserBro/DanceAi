import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../theme/stage_theme.dart';

/// Маркер точек линии — чтобы линии различались, даже когда совпадают.
enum RadarMarker { dot, diamond, ring }

class RadarSeries {
  const RadarSeries({
    required this.label,
    required this.color,
    required this.values,
    this.filled = false,
    this.marker = RadarMarker.dot,
    this.lineOffset = 0,
  });

  final String label;
  final Color color;

  /// По одному значению на ось; null — нет оценки. Отсутствующая оценка
  /// никогда не рисуется как 0 или центр: на этой оси у линии разрыв.
  final List<int?> values;
  final bool filled;
  final RadarMarker marker;

  /// Сдвиг линии вбок, px: линии партнёра и партнёрши идут параллельно
  /// линии пары и видны, даже когда оценки совпадают.
  final double lineOffset;

  /// Серия показывается, если есть хотя бы одна оценка.
  bool get hasAny => values.any((v) => v != null);

  /// Индексы осей без оценки.
  List<int> get missing => [
        for (var i = 0; i < values.length; i++)
          if (values[i] == null) i,
      ];
}

/// Отрезок линии серии между соседними осями [from] и [to].
typedef RadarSegment = ({int from, int to});

/// Отрезки линии серии: только между соседними осями, где обе оценки есть.
/// На оси без оценки — разрыв: отсутствующая оценка не рисуется ни как 0,
/// ни как центр, и линия не проходит через центр к дальней оси.
List<RadarSegment> radarSegments(List<int?> values) {
  final n = values.length;
  if (n < 2) return const [];
  return [
    for (var i = 0; i < n; i++)
      if (values[i] != null && values[(i + 1) % n] != null && (n > 2 || i == 0))
        (from: i, to: (i + 1) % n),
  ];
}

/// Радар-диаграмма по компонентам (spec 6): пара — заливкой,
/// партнёр и партнёрша — линиями поверх. Вырастает из центра при появлении.
class RadarChart extends StatefulWidget {
  const RadarChart({
    super.key,
    required this.axes,
    required this.series,
    this.max = 10,
  });

  final List<String> axes;
  final List<RadarSeries> series;
  final int max;

  @override
  State<RadarChart> createState() => _RadarChartState();
}

class _RadarChartState extends State<RadarChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _grow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _grow.value = 1;
    } else if (_grow.value == 0) {
      _grow.forward();
    }
  }

  @override
  void dispose() {
    _grow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.series.where((s) => s.hasAny).toList();
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 1.15,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _RadarPainter(
                progress:
                    CurvedAnimation(parent: _grow, curve: Curves.easeOutBack),
                axes: widget.axes,
                series: visible,
                max: widget.max,
                labelStyle:
                    StageText.label(12, color: StageColors.textSecondary),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          alignment: WrapAlignment.center,
          children: [
            for (final s in visible)
              RadarLegendItem(
                series: s,
                missing: [for (final i in s.missing) widget.axes[i]],
              ),
          ],
        ),
      ],
    );
  }
}

class RadarLegendItem extends StatelessWidget {
  const RadarLegendItem(
      {super.key, required this.series, required this.missing});

  final RadarSeries series;

  /// Названия компонентов без оценки.
  final List<String> missing;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 22,
          height: 12,
          child: CustomPaint(painter: _LegendSwatch(series)),
        ),
        const SizedBox(width: 6),
        Text(series.label,
            style: StageText.label(12, color: StageColors.textSecondary)),
        if (missing.isNotEmpty)
          Flexible(
            child: Text(
              ' · нет оценки: ${missing.join(', ')}',
              style: StageText.label(12, color: StageColors.textMuted),
            ),
          ),
      ],
    );
  }
}

class _LegendSwatch extends CustomPainter {
  _LegendSwatch(this.series);
  final RadarSeries series;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = series.color
        ..strokeWidth = series.filled ? 3 : 2
        ..strokeCap = StrokeCap.round,
    );
    _drawMarker(canvas, Offset(size.width / 2, y), series);
  }

  @override
  bool shouldRepaint(_LegendSwatch old) => old.series != series;
}

void _drawMarker(Canvas canvas, Offset c, RadarSeries s) {
  final fill = Paint()..color = s.color;
  final halo = Paint()..color = StageColors.backgroundDeep;
  switch (s.marker) {
    case RadarMarker.dot:
      canvas.drawCircle(
          c, 6, Paint()..color = s.color.withValues(alpha: 0.25));
      canvas.drawCircle(c, 3.2, fill);
    case RadarMarker.diamond:
      Path diamond(double r) => Path()
        ..moveTo(c.dx, c.dy - r)
        ..lineTo(c.dx + r, c.dy)
        ..lineTo(c.dx, c.dy + r)
        ..lineTo(c.dx - r, c.dy)
        ..close();
      canvas.drawPath(diamond(4.6), halo);
      canvas.drawPath(diamond(3.4), fill);
    case RadarMarker.ring:
      // Без заливки: ромб партнёра в той же точке остаётся виден.
      canvas.drawCircle(
          c,
          6,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = s.color);
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.progress,
    required this.axes,
    required this.series,
    required this.max,
    required this.labelStyle,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final List<String> axes;
  final List<RadarSeries> series;
  final int max;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final n = axes.length;
    if (n < 3) return;
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) * 0.32;
    final p = progress.value;

    Offset point(int i, double r) {
      final angle = -math.pi / 2 + 2 * math.pi * i / n;
      return center + Offset(math.cos(angle), math.sin(angle)) * r;
    }

    // Сетка: 5 колец (2, 4, 6, 8, 10) и оси.
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = StageColors.textPrimary.withValues(alpha: 0.08);
    for (var ring = 1; ring <= 5; ring++) {
      final r = radius * ring / 5;
      final path = Path()..moveTo(point(0, r).dx, point(0, r).dy);
      for (var i = 1; i < n; i++) {
        path.lineTo(point(i, r).dx, point(i, r).dy);
      }
      path.close();
      canvas.drawPath(path, grid);
    }
    for (var i = 0; i < n; i++) {
      canvas.drawLine(center, point(i, radius), grid);
    }

    // Подписи осей.
    for (var i = 0; i < n; i++) {
      final tp = TextPainter(
        text: TextSpan(text: axes[i], style: labelStyle),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: 2,
      )..layout(maxWidth: size.width * 0.34);
      final anchor = point(i, radius + 18);
      final dx = anchor.dx - tp.width / 2;
      final dy = anchor.dy - tp.height / 2;
      tp.paint(
        canvas,
        Offset(dx.clamp(0, size.width - tp.width),
            dy.clamp(0, size.height - tp.height)),
      );
    }

    // Сначала пара (заливка), поверх — линии людей: они не теряются под
    // заливкой и видны, даже когда совпадают с линией пары.
    final ordered = [
      ...series.where((s) => s.filled),
      ...series.where((s) => !s.filled),
    ];
    for (final s in ordered) {
      Offset? at(int i) {
        final v = s.values[i];
        if (v == null) return null;
        return point(i, radius * (v / max).clamp(0.0, 1.0) * p);
      }

      if (s.filled && s.missing.isEmpty) {
        final path = Path();
        for (var i = 0; i < n; i++) {
          final pt = at(i)!;
          i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
        }
        path.close();
        canvas.drawPath(
          path,
          Paint()
            ..shader = RadialGradient(colors: [
              s.color.withValues(alpha: 0.10),
              s.color.withValues(alpha: 0.38),
            ]).createShader(Rect.fromCircle(center: center, radius: radius)),
        );
      }

      final line = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.filled ? 2.6 : 1.8
        ..strokeCap = StrokeCap.round
        ..color = s.color;
      for (final seg in radarSegments(s.values)) {
        final a = at(seg.from)!;
        final b = at(seg.to)!;
        var shift = Offset.zero;
        final len = (b - a).distance;
        if (s.lineOffset != 0 && len > 0) {
          // Нормаль к отрезку, наружу от центра.
          var normal = Offset(-(b - a).dy, (b - a).dx) / len;
          final mid = (a + b) / 2;
          if ((mid - center).dx * normal.dx + (mid - center).dy * normal.dy < 0) {
            normal = -normal;
          }
          shift = normal * s.lineOffset;
        }
        canvas.drawLine(a + shift, b + shift, line);
      }
      for (var i = 0; i < n; i++) {
        final pt = at(i);
        if (pt != null) _drawMarker(canvas, pt, s);
      }
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.series != series || old.axes != axes;
}
