import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../app/routes.dart';
import '../../data/criteria.dart';
import '../../theme/stage_theme.dart';
import '../format.dart';
import '../widgets/common.dart';
import 'settings_screen.dart';
import 'shooting_guide_screen.dart';
import 'video_screen.dart';

/// Главный: выбор танца (spec 8б.1).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final catalog = services.data.criteria;
    final wide = isWide(context);

    Widget group(DanceStyle style, int baseIndex) {
      final dances = catalog.dances.where((d) => d.style == style).toList();
      final accent = DanceAccent.of(style);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StaggeredAppear(
            index: baseIndex,
            child: Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12, top: 8),
              child: Row(
                children: [
                  Container(
                    width: 22,
                    height: 2,
                    decoration: BoxDecoration(gradient: accent.gradient),
                  ),
                  const SizedBox(width: 10),
                  Text(style.labelRu.toUpperCase(),
                      style: StageText.label(13,
                          weight: 700, color: accent.primary)),
                ],
              ),
            ),
          ),
          for (var i = 0; i < dances.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: StaggeredAppear(
                index: baseIndex + 1 + i,
                child: _DanceCard(
                  dance: dances[i],
                  criteriaCount: catalog.criteriaFor(dances[i]).length,
                ),
              ),
            ),
        ],
      );
    }

    return StageScaffold(
      automaticallyImplyLeading: false,
      actions: [
        IconButton(
          tooltip: 'Инструкция по съёмке',
          icon: const Icon(Icons.videocam_outlined),
          onPressed: () =>
              Navigator.of(context).push(stageRoute(const ShootingGuideScreen())),
        ),
        IconButton(
          tooltip: 'Настройки',
          icon: const Icon(Icons.tune_rounded),
          onPressed: () =>
              Navigator.of(context).push(stageRoute(const SettingsScreen())),
        ),
        const SizedBox(width: 8),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          StaggeredAppear(
            index: 0,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ShaderMask(
                    shaderCallback: (r) => const LinearGradient(colors: [
                      StageColors.textPrimary,
                      StageColors.spotlightWarm,
                    ]).createShader(r),
                    child: Text('DanceAI',
                        style: StageText.display(wide ? 52 : 42)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Оценка танца пары по видео: техника, музыка, партнёрство, '
                    'хореография. Выберите танец.',
                    style: StageText.body(15.5,
                        color: StageColors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: group(DanceStyle.standard, 1)),
                const SizedBox(width: 24),
                Expanded(child: group(DanceStyle.latin, 1)),
              ],
            )
          else ...[
            group(DanceStyle.standard, 1),
            const SizedBox(height: 8),
            group(DanceStyle.latin, 4),
          ],
          const SizedBox(height: 8),
          StaggeredAppear(
            index: 7,
            child: GlowCard(
              onTap: () => Navigator.of(context)
                  .push(stageRoute(const ShootingGuideScreen())),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  const Icon(Icons.lightbulb_outline_rounded,
                      color: StageColors.spotlightWarm),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Как снять видео, чтобы оценка была точнее',
                      style: StageText.body(14.5, weight: 600),
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded,
                      color: StageColors.textMuted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DanceCard extends StatelessWidget {
  const _DanceCard({required this.dance, required this.criteriaCount});

  final Dance dance;
  final int criteriaCount;

  @override
  Widget build(BuildContext context) {
    final accent = DanceAccent.of(dance.style);
    final m = dance.music;
    return GlowCard(
      accent: accent,
      glow: 0.15,
      onTap: () =>
          Navigator.of(context).push(stageRoute(VideoScreen(dance: dance))),
      padding: const EdgeInsets.fromLTRB(22, 20, 18, 20),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Hero(
                  tag: 'dance-title-${dance.id}',
                  child: Material(
                    type: MaterialType.transparency,
                    child: Text(dance.nameRu, style: StageText.display(26)),
                  ),
                ),
                const SizedBox(height: 4),
                Text(dance.nameEn,
                    style: StageText.label(13, color: accent.secondary)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _Tag('${m.meter} · ${m.tempoMinMpm}–${m.tempoMaxMpm} т/мин'),
                    _Tag(countLabel(criteriaCount, 'критерий', 'критерия', 'критериев')),
                    _Tag(countLabel(dance.figures.length, 'фигура', 'фигуры', 'фигур')),
                  ],
                ),
              ],
            ),
          ),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: accent.gradient,
              boxShadow: [
                BoxShadow(
                    color: accent.glow.withValues(alpha: 0.5), blurRadius: 18),
              ],
            ),
            child: const Icon(Icons.arrow_forward_rounded,
                color: StageColors.backgroundDeep),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: StageColors.textPrimary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text,
            style: StageText.label(11.5, color: StageColors.textSecondary)),
      );
}
