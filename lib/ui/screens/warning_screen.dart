import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../data/criteria.dart';
import '../../report/report.dart';
import '../../report/report_labels.dart';
import '../../theme/stage_theme.dart';
import '../video_session.dart';
import '../widgets/common.dart';
import 'report_screen.dart';

/// Предупреждение при status ≠ ok (spec 4, 8б.4).
class WarningScreen extends StatelessWidget {
  const WarningScreen({
    super.key,
    required this.report,
    required this.dance,
    required this.session,
  });

  final DanceReport report;
  final Dance dance;
  final VideoSession session;

  @override
  Widget build(BuildContext context) {
    final va = report.videoAssessment;
    final unusable = va.status == VideoStatus.unusable;
    final color = unusable ? StageColors.poor : StageColors.partial;
    final accent = DanceAccent.of(dance.style);

    return StageScaffold(
      accent: accent,
      maxWidth: 760,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          StaggeredAppear(
            index: 0,
            child: Row(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.14),
                    border: Border.all(color: color.withValues(alpha: 0.5)),
                  ),
                  child: Icon(
                      unusable
                          ? Icons.videocam_off_rounded
                          : Icons.warning_amber_rounded,
                      color: color),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(va.status.labelRu,
                      style: StageText.display(28)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          StaggeredAppear(
            index: 1,
            child: Text(
              unusable
                  ? 'ИИ не смог оценить танец по этому видео. Оценки ниже будут '
                      'почти бессмысленными.'
                  : 'ИИ оценил танец, но часть критериев видна плохо — '
                      'оценка может быть неточной.',
              style: StageText.body(15.5, color: StageColors.textSecondary),
            ),
          ),
          const SizedBox(height: 20),
          StaggeredAppear(
            index: 2,
            child: GlowCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Причины', style: StageText.display(19)),
                  const SizedBox(height: 12),
                  BulletList(va.issues,
                      color: color, empty: 'ИИ не указал причин.'),
                  const SizedBox(height: 8),
                  Text('Кого оценил ИИ', style: StageText.label(13,
                      color: StageColors.textMuted)),
                  const SizedBox(height: 4),
                  Text(va.coupleDescription, style: StageText.body(14)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          StaggeredAppear(
            index: 3,
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                PrimaryButton(
                  label: 'Загрузить другое видео',
                  icon: Icons.video_library_rounded,
                  accent: accent,
                  onPressed: () {
                    Navigator.of(context).pop();
                    session.onChooseOther?.call();
                  },
                ),
                GhostButton(
                  label: 'Показать оценку всё равно',
                  icon: Icons.visibility_outlined,
                  onPressed: () => Navigator.of(context).pushReplacement(
                    stageRoute(ReportScreen(
                        report: report, dance: dance, session: session)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
