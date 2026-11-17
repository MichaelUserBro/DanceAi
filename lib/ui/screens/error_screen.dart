import 'package:material_ui/material_ui.dart';

import '../../analysis/analysis_failure.dart';
import '../../app/routes.dart';
import '../../theme/stage_theme.dart';
import '../video_session.dart';
import '../widgets/common.dart';
import 'analysis_screen.dart';
import 'settings_screen.dart';

/// Экран ошибки (spec 8б.6): понятный текст и действия.
class ErrorScreen extends StatelessWidget {
  const ErrorScreen({super.key, required this.failure, required this.session});

  final AnalysisFailure failure;
  final VideoSession session;

  @override
  Widget build(BuildContext context) {
    final accent = DanceAccent.of(session.dance.style);
    final canRetry = session.hasVideo;

    Widget action(FailureAction a, bool primary) {
      final (label, icon, onPressed) = switch (a) {
        FailureAction.retry => (
            'Повторить',
            Icons.refresh_rounded,
            canRetry
                ? () => Navigator.of(context).pushReplacement(
                    stageRoute(AnalysisScreen(session: session)))
                : null,
          ),
        FailureAction.chooseOtherVideo => (
            'Выбрать другое видео',
            Icons.video_library_rounded,
            () {
              Navigator.of(context).pop();
              session.onChooseOther?.call();
            },
          ),
        FailureAction.sendFrames => (
            'Отправить кадрами',
            Icons.burst_mode_rounded,
            canRetry
                ? () => Navigator.of(context).pushReplacement(stageRoute(
                    AnalysisScreen(session: session, forceFrames: true)))
                : null,
          ),
        FailureAction.openSettings => (
            'Открыть настройки',
            Icons.tune_rounded,
            () => Navigator.of(context).push(stageRoute(const SettingsScreen())),
          ),
      };
      return primary
          ? PrimaryButton(
              label: label, icon: icon, accent: accent, onPressed: onPressed)
          : GhostButton(label: label, icon: icon, onPressed: onPressed);
    }

    final actions = failure.actions;
    return StageScaffold(
      accent: accent,
      maxWidth: 720,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          StaggeredAppear(
            index: 0,
            child: Center(
              child: Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: StageColors.poor.withValues(alpha: 0.12),
                  border: Border.all(
                      color: StageColors.poor.withValues(alpha: 0.45)),
                  boxShadow: [
                    BoxShadow(
                        color: StageColors.poor.withValues(alpha: 0.25),
                        blurRadius: 30),
                  ],
                ),
                child: Icon(_icon(failure.kind),
                    size: 34, color: StageColors.poor),
              ),
            ),
          ),
          const SizedBox(height: 20),
          StaggeredAppear(
            index: 1,
            child: Text(failure.title,
                textAlign: TextAlign.center, style: StageText.display(28)),
          ),
          const SizedBox(height: 12),
          StaggeredAppear(
            index: 2,
            child: Text(failure.message,
                textAlign: TextAlign.center,
                style:
                    StageText.body(15.5, color: StageColors.textSecondary)),
          ),
          const SizedBox(height: 28),
          StaggeredAppear(
            index: 3,
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                for (var i = 0; i < actions.length; i++)
                  action(actions[i], i == 0),
              ],
            ),
          ),
          if (failure.details.isNotEmpty) ...[
            const SizedBox(height: 28),
            StaggeredAppear(
              index: 4,
              child: Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('Технические подробности',
                      style: StageText.label(13,
                          color: StageColors.textMuted)),
                  children: [
                    SelectableText(
                      failure.details.take(40).join('\n'),
                      style: StageText.body(12.5,
                          color: StageColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static IconData _icon(FailureKind k) => switch (k) {
        FailureKind.noAudio => Icons.volume_off_rounded,
        FailureKind.unreadableVideo => Icons.broken_image_outlined,
        FailureKind.invalidKey || FailureKind.notConfigured =>
          Icons.key_off_rounded,
        FailureKind.rateLimit => Icons.hourglass_bottom_rounded,
        FailureKind.network => Icons.wifi_off_rounded,
        FailureKind.tooLarge || FailureKind.videoTooLarge =>
          Icons.sd_card_alert_outlined,
        FailureKind.videoEncodeFailed => Icons.movie_filter_outlined,
        FailureKind.modelUnavailable => Icons.psychology_alt_outlined,
        FailureKind.insufficientFunds => Icons.account_balance_wallet_outlined,
        FailureKind.blocked => Icons.block_rounded,
        FailureKind.invalidResponse => Icons.rule_rounded,
        FailureKind.server || FailureKind.internal =>
          Icons.error_outline_rounded,
      };
}
