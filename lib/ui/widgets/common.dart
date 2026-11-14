import 'package:material_ui/material_ui.dart';

import '../../report/report.dart';
import '../../report/report_labels.dart';
import '../../theme/stage_theme.dart';
import 'stage_background.dart';

/// Ширина окна, с которой вёрстка переходит в две колонки.
const double kWideLayout = 900;

bool isWide(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kWideLayout;

/// Каркас экрана: сцена на фоне, прозрачная шапка, ограниченная ширина.
class StageScaffold extends StatelessWidget {
  const StageScaffold({
    super.key,
    required this.body,
    this.title,
    this.accent = DanceAccent.neutral,
    this.actions,
    this.maxWidth = 1180,
    this.intensity = 1.0,
    this.leading,
    this.automaticallyImplyLeading = true,
  });

  final Widget body;
  final String? title;
  final DanceAccent accent;
  final List<Widget>? actions;
  final double maxWidth;
  final double intensity;
  final Widget? leading;
  final bool automaticallyImplyLeading;

  @override
  Widget build(BuildContext context) {
    return StageBackground(
      accent: accent,
      intensity: intensity,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: title == null ? null : Text(title!),
          actions: actions,
          leading: leading,
          automaticallyImplyLeading: automaticallyImplyLeading,
        ),
        body: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

/// Карточка со стеклянной подложкой и свечением акцента.
class GlowCard extends StatefulWidget {
  const GlowCard({
    super.key,
    required this.child,
    this.accent,
    this.onTap,
    this.padding = const EdgeInsets.all(20),
    this.glow = 0.0,
  });

  final Widget child;
  final DanceAccent? accent;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  /// Постоянное свечение 0..1 (у интерактивных карточек растёт при наведении).
  final double glow;

  @override
  State<GlowCard> createState() => _GlowCardState();
}

class _GlowCardState extends State<GlowCard> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    final interactive = widget.onTap != null;
    final glow = (widget.glow + (_hover ? 0.6 : 0)).clamp(0.0, 1.0);
    final borderColor = accent == null
        ? StageColors.outline
        : accent.primary.withValues(alpha: 0.18 + 0.4 * glow);

    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      padding: widget.padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            StageColors.surfaceHigh.withValues(alpha: 0.92),
            StageColors.surface.withValues(alpha: 0.86),
          ],
        ),
        border: Border.all(color: borderColor, width: 1),
        boxShadow: [
          if (accent != null && glow > 0)
            BoxShadow(
              color: accent.glow.withValues(alpha: 0.35 * glow),
              blurRadius: 36,
              spreadRadius: -6,
            ),
          const BoxShadow(
            color: Color(0x66000000),
            blurRadius: 24,
            offset: Offset(0, 12),
            spreadRadius: -10,
          ),
        ],
      ),
      child: widget.child,
    );

    if (!interactive) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.975 : (_hover ? 1.012 : 1.0),
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: card,
        ),
      ),
    );
  }
}

/// Главная кнопка: градиент акцента и мягкое свечение.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.accent = DanceAccent.neutral,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final DanceAccent accent;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 20, color: StageColors.backgroundDeep),
          const SizedBox(width: 10),
        ],
        Flexible(
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: StageText.label(15.5,
                weight: 700, color: StageColors.backgroundDeep),
          ),
        ),
      ],
    );
    return AnimatedOpacity(
      opacity: enabled ? 1 : 0.4,
      duration: const Duration(milliseconds: 200),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: accent.gradient,
          borderRadius: BorderRadius.circular(40),
          boxShadow: [
            if (enabled)
              BoxShadow(
                color: accent.glow.withValues(alpha: 0.45),
                blurRadius: 24,
                spreadRadius: -4,
                offset: const Offset(0, 6),
              ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(40),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// Второстепенная кнопка: контур.
class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color = StageColors.textPrimary,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon == null ? null : Icon(icon, size: 19),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.35)),
        textStyle: StageText.label(14.5),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
        shape: const StadiumBorder(),
      ),
    );
  }
}

/// Появление с задержкой по индексу: проявление + подъём.
class StaggeredAppear extends StatelessWidget {
  const StaggeredAppear({
    super.key,
    required this.index,
    required this.child,
    this.step = const Duration(milliseconds: 60),
  });

  final int index;
  final Widget child;
  final Duration step;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return child;
    final delayMs = (step.inMilliseconds * index).clamp(0, 700);
    const animMs = 520;
    final total = delayMs + animMs;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      child: child,
      builder: (context, v, child) {
        final local = ((v * total - delayMs) / animMs).clamp(0.0, 1.0);
        final e = Curves.easeOutCubic.transform(local);
        return Opacity(
          opacity: e,
          child: Transform.translate(
            offset: Offset(0, 18 * (1 - e)),
            child: child,
          ),
        );
      },
    );
  }
}

/// Счётчик: число «набегает» от 0 до значения.
class AnimatedCounter extends StatelessWidget {
  const AnimatedCounter({
    super.key,
    required this.value,
    required this.style,
    this.decimals = 0,
    this.duration = const Duration(milliseconds: 1400),
  });

  final double value;
  final TextStyle style;
  final int decimals;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final instant = MediaQuery.of(context).disableAnimations;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: instant ? value : 0, end: value),
      duration: instant ? Duration.zero : duration,
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Text(
        v.toStringAsFixed(decimals).replaceAll('.', ','),
        style: style.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Row(
        children: [
          Expanded(child: Text(text, style: StageText.display(21))),
          ?trailing,
        ],
      ),
    );
  }
}

/// Пилюля с цветной точкой: вердикт, серьёзность, метка.
class Pill extends StatelessWidget {
  const Pill({super.key, required this.label, required this.color, this.dense = false});

  final String label;
  final Color color;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: dense ? 8 : 10, vertical: dense ? 3 : 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: StageText.label(dense ? 11.5 : 12.5, color: color)),
        ],
      ),
    );
  }
}

class VerdictPill extends StatelessWidget {
  const VerdictPill(this.verdict, {super.key, this.prefix, this.dense = false});

  final Verdict verdict;
  final String? prefix;
  final bool dense;

  @override
  Widget build(BuildContext context) => Pill(
        label: prefix == null ? verdict.labelRu : '$prefix: ${verdict.labelRu}',
        color: StageColors.verdict(verdict),
        dense: dense,
      );
}

class SeverityPill extends StatelessWidget {
  const SeverityPill(this.severity, {super.key});

  final Severity severity;

  @override
  Widget build(BuildContext context) => Pill(
        label: severity.labelRu,
        color: StageColors.severity(severity),
        dense: true,
      );
}

/// Две колонки на широком окне, одна — на телефоне.
class ResponsiveSplit extends StatelessWidget {
  const ResponsiveSplit({
    super.key,
    required this.first,
    required this.second,
    this.firstFlex = 5,
    this.secondFlex = 6,
    this.gap = 24,
  });

  final Widget first;
  final Widget second;
  final int firstFlex;
  final int secondFlex;
  final double gap;

  @override
  Widget build(BuildContext context) {
    if (!isWide(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [first, SizedBox(height: gap), second],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: firstFlex, child: first),
        SizedBox(width: gap),
        Expanded(flex: secondFlex, child: second),
      ],
    );
  }
}

/// Маркированный список строк.
class BulletList extends StatelessWidget {
  const BulletList(this.items, {super.key, this.color, this.empty});

  final List<String> items;
  final Color? color;
  final String? empty;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Text(empty ?? '—',
          style: StageText.body(14, color: StageColors.textMuted));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 10),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: color ?? StageColors.textSecondary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(child: Text(item, style: StageText.body(14.5))),
              ],
            ),
          ),
      ],
    );
  }
}
