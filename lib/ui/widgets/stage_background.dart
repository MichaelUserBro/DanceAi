import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../theme/stage_theme.dart';

/// Фон «сцена»: тёмный зал и медленно плывущие мягкие прожекторы.
/// Рисуется одним CustomPainter в отдельном слое (RepaintBoundary),
/// поэтому не перерисовывает содержимое экрана.
class StageBackground extends StatefulWidget {
  const StageBackground({
    super.key,
    required this.child,
    this.accent = DanceAccent.neutral,
    this.intensity = 1.0,
  });

  final Widget child;
  final DanceAccent accent;

  /// 0..1+ — яркость прожекторов (экран анализа делает её «живой»).
  final double intensity;

  @override
  State<StageBackground> createState() => _StageBackgroundState();
}

class _StageBackgroundState extends State<StageBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _drift.stop();
    } else if (!_drift.isAnimating) {
      _drift.repeat();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: widget.accent.primary),
            duration: const Duration(milliseconds: 600),
            builder: (context, color, _) => CustomPaint(
              painter: _SpotlightPainter(
                progress: _drift,
                accent: color ?? widget.accent.primary,
                intensity: widget.intensity,
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter({
    required this.progress,
    required this.accent,
    required this.intensity,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final Color accent;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [StageColors.background, StageColors.backgroundDeep],
        ).createShader(rect),
    );

    final t = progress.value * 2 * math.pi;
    final side = size.longestSide;
    final k = intensity.clamp(0.0, 1.6);

    void spot(Offset center, double radius, Color color, double alpha) {
      final r = Rect.fromCircle(center: center, radius: radius);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(colors: [
            color.withValues(alpha: alpha * k),
            color.withValues(alpha: 0),
          ]).createShader(r),
      );
    }

    // Главный луч сверху — цвет акцента танца.
    spot(
      Offset(size.width * (0.5 + 0.18 * math.sin(t)), -side * 0.08),
      side * 0.62,
      accent,
      0.20,
    );
    // Тёплый боковой — как свет из-за кулис.
    spot(
      Offset(size.width * (0.05 + 0.08 * math.cos(t * 0.7)),
          size.height * (0.55 + 0.1 * math.sin(t * 0.9))),
      side * 0.45,
      StageColors.spotlightWarm,
      0.07,
    );
    // Холодный контровой справа снизу.
    spot(
      Offset(size.width * (0.95 - 0.06 * math.sin(t * 1.3)),
          size.height * (0.95 + 0.04 * math.cos(t))),
      side * 0.5,
      StageColors.spotlight,
      0.10,
    );

    // Лёгкое затемнение краёв (виньетка).
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          radius: 1.1,
          colors: [
            Colors.transparent,
            StageColors.backgroundDeep.withValues(alpha: 0.65),
          ],
          stops: const [0.55, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.accent != accent || old.intensity != intensity;
}
