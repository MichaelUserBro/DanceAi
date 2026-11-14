import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../theme/stage_theme.dart';

class RadarSeries {
  const RadarSeries({
    required this.label,
    required this.color,
    required this.values,
    this.filled = false,
  });

  final String label;
  final Color color;

  /// По одному значению на ось; null — нет оценки (точка не рисуется,
  /// линия идёт через центр не будет — серия пропускается целиком).
  final List<int?> values;
  final bool filled;

  bool get isComplete => values.every((v) => v != null);
}

/// Радар-диаграмма по компонентам (spec 6): пара — заливкой,
/// партнёр и партнёрша — линиями. Вырастает из центра при появлении.
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
    final visible = widget.series.where((s) => s.isComplete).toList();
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 1.15,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _RadarPainter(
                progress: CurvedAnimation(
                    parent: _grow, curve: Curves.easeOutBack),
                axes: widget.axes,
                series: visible,
                max: widget.max,
                labelStyle: StageText.label(12, color: StageColors.textSecondary),
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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 14,
                    height: 3,
                    decoration: BoxDecoration(
                      color: s.color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(s.label,
                      style: StageText.label(12,
                          color: StageColors.textSecondary)),
                ],
              ),
          ],
        ),
      ],
    );
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

    // Серии: сначала заливки, потом линии и точки.
    for (final s in series) {
      final path = Path();
      for (var i = 0; i < n; i++) {
        final v = (s.values[i]! / max).clamp(0.0, 1.0) * p;
        final pt = point(i, radius * v);
        i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
      }
      path.close();
      if (s.filled) {
        canvas.drawPath(
          path,
          Paint()
            ..shader = RadialGradient(colors: [
              s.color.withValues(alpha: 0.10),
              s.color.withValues(alpha: 0.38),
            ]).createShader(Rect.fromCircle(center: center, radius: radius)),
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s.filled ? 2.4 : 1.6
          ..strokeJoin = StrokeJoin.round
          ..color = s.color.withValues(alpha: s.filled ? 1 : 0.85),
      );
      if (s.filled) {
        for (var i = 0; i < n; i++) {
          final v = (s.values[i]! / max).clamp(0.0, 1.0) * p;
          final pt = point(i, radius * v);
          canvas.drawCircle(pt, 6,
              Paint()..color = s.color.withValues(alpha: 0.25));
          canvas.drawCircle(pt, 3.2, Paint()..color = s.color);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.series != series || old.axes != axes;
}
