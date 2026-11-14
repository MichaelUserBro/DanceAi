import 'package:material_ui/material_ui.dart';

import '../../theme/stage_theme.dart';
import '../widgets/common.dart';

/// Инструкция по съёмке (spec 4, 8б.8).
class ShootingGuideScreen extends StatelessWidget {
  const ShootingGuideScreen({super.key});

  static const _tips = [
    (
      Icons.center_focus_strong_rounded,
      'Пара — главная в кадре',
      'Чем ближе и лучше видна пара, тем точнее оценка. Пара должна занимать '
          'заметную часть кадра, а не быть точкой у дальней стены.',
    ),
    (
      Icons.people_alt_outlined,
      'Понятно, кого оценивать',
      'Оценивается пара, которая большую часть времени в кадре или с которой '
          'начинается запись. Если в кадре несколько пар — начните съёмку с '
          'нужной и держите её в центре.',
    ),
    (
      Icons.directions_walk_rounded,
      'Видны ноги',
      'Многие критерии — про стопы и колени. Снимайте пару целиком, '
          'с ногами, без обрезки снизу.',
    ),
    (
      Icons.music_note_rounded,
      'Со звуком',
      'Музыка обязательна: без неё нельзя оценить попадание в такт. '
          'Не выключайте звук при съёмке.',
    ),
    (
      Icons.wb_sunny_outlined,
      'Свет и устойчивость',
      'Хорошее освещение, камера без резких рывков. Лучше с одной точки, '
          'горизонтально или вертикально — неважно.',
    ),
    (
      Icons.timer_outlined,
      'Танец целиком',
      'Подойдёт любое видео — тренировка или турнир. Лучше весь танец '
          'или длинный фрагмент, а не пару тактов.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final cards = [
      for (var i = 0; i < _tips.length; i++)
        StaggeredAppear(
          index: i + 1,
          child: GlowCard(
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_tips[i].$1, color: StageColors.spotlightWarm, size: 26),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_tips[i].$2, style: StageText.body(16, weight: 700)),
                      const SizedBox(height: 4),
                      Text(_tips[i].$3,
                          style: StageText.body(14,
                              color: StageColors.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
    ];

    return StageScaffold(
      title: 'Как снимать',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          StaggeredAppear(
            index: 0,
            child: Text(
              'Шесть правил, чтобы ИИ оценил именно вашу пару и как можно точнее.',
              style: StageText.body(15.5, color: StageColors.textSecondary),
            ),
          ),
          const SizedBox(height: 18),
          if (wide)
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final c in cards)
                  SizedBox(
                    width: (MediaQuery.sizeOf(context).width.clamp(0, 1180) -
                            40 -
                            16) /
                        2,
                    child: c,
                  ),
              ],
            )
          else
            for (final c in cards)
              Padding(padding: const EdgeInsets.only(bottom: 12), child: c),
        ],
      ),
    );
  }
}
