import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/providers_catalog.dart';
import '../../theme/stage_theme.dart';
import '../widgets/common.dart';

/// «Как получить ключ» по провайдеру — из providers.json (spec 8б.8).
class KeyHelpScreen extends StatelessWidget {
  const KeyHelpScreen({super.key, required this.provider});

  final ProviderInfo provider;

  Future<void> _open(BuildContext context, String url) async {
    final ok = await launchUrl(Uri.parse(url),
        mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось открыть ссылку')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = provider;
    final url = p.keyUrl;
    return StageScaffold(
      title: 'Как получить ключ',
      maxWidth: 760,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          StaggeredAppear(
              index: 0, child: Text(p.name, style: StageText.display(30))),
          if (p.freeNoteRu != null) ...[
            const SizedBox(height: 8),
            StaggeredAppear(
              index: 1,
              child: Text(p.freeNoteRu!,
                  style: StageText.body(15, color: StageColors.textSecondary)),
            ),
          ],
          const SizedBox(height: 20),
          for (var i = 0; i < p.keyStepsRu.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: StaggeredAppear(
                index: 2 + i,
                child: GlowCard(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: DanceAccent.neutral.gradient,
                        ),
                        child: Text('${i + 1}',
                            style: StageText.label(14,
                                weight: 800,
                                color: StageColors.backgroundDeep)),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(p.keyStepsRu[i],
                              style: StageText.body(15)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (url != null) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                PrimaryButton(
                  label: 'Открыть страницу ключей',
                  icon: Icons.open_in_new_rounded,
                  onPressed: () => _open(context, url),
                ),
                GhostButton(
                  label: 'Скопировать ссылку',
                  icon: Icons.copy_rounded,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: url));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Ссылка скопирована')));
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(url,
                style: StageText.body(13, color: StageColors.textMuted)),
          ],
          const SizedBox(height: 16),
          Text(
            'Если провайдер недоступен в вашей стране, может понадобиться VPN — '
            'это настраивается вне приложения.',
            style: StageText.body(13, color: StageColors.textMuted),
          ),
        ],
      ),
    );
  }
}
