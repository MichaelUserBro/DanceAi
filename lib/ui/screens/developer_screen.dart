import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../analysis/stub_ai_provider.dart';
import '../../analysis/video_preparer.dart';
import '../../app/app_scope.dart';
import '../../theme/stage_theme.dart';
import '../format.dart';
import '../widgets/common.dart';

/// «Для разработчика» (spec 7.8): сценарий заглушки, собранный промпт,
/// анализ музыки и ответы ИИ последнего анализа. Ключа здесь нет.
class DeveloperScreen extends StatelessWidget {
  const DeveloperScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final settings = services.settings;
    return ListenableBuilder(
      listenable: Listenable.merge([settings, services.dev]),
      builder: (context, _) {
        final trace = services.dev.lastTrace;
        final scenarios = GlowCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Сценарий заглушки ИИ', style: StageText.display(20)),
              const SizedBox(height: 4),
              Text('Что вернёт заглушка при следующем анализе',
                  style: StageText.body(13, color: StageColors.textMuted)),
              const SizedBox(height: 8),
              RadioGroup<StubScenario>(
                groupValue: settings.stubScenario,
                onChanged: (v) {
                  if (v != null) settings.setStubScenario(v);
                },
                child: Column(
                  children: [
                    for (final s in StubScenario.values)
                      RadioListTile<StubScenario>(
                        value: s,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(s.labelRu, style: StageText.body(14.5)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );

        final last = GlowCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Последний анализ', style: StageText.display(20)),
              const SizedBox(height: 10),
              if (trace == null || trace.prompt == null)
                Text(
                  'Пока не было анализа. Запустите оценку любого видео — '
                  'здесь появятся собранный промпт и анализ музыки.',
                  style: StageText.body(14, color: StageColors.textMuted),
                )
              else ...[
                _kv('Способ подачи',
                    trace.mode == SubmissionMode.video ? 'видео целиком' : 'кадры'),
                _kv('Длительность', formatDuration(trace.durationSec)),
                _kv('Кадров', '${trace.frameCount ?? 0}'),
                _kv('Ответов ИИ', '${trace.responses.length}'),
                const SizedBox(height: 12),
                _Block(title: 'Анализ музыки', text: trace.musicAnalysis ?? ''),
                _Block(title: 'Системный промпт', text: trace.prompt!.system),
                _Block(title: 'Запрос', text: trace.prompt!.user),
                for (var i = 0; i < trace.responses.length; i++)
                  _Block(title: 'Ответ ИИ №${i + 1}', text: trace.responses[i]),
                for (var i = 0; i < trace.problems.length; i++)
                  _Block(
                      title: 'Ошибки проверки ответа №${i + 1}',
                      text: trace.problems[i].join('\n')),
              ],
            ],
          ),
        );

        return StageScaffold(
          title: 'Для разработчика',
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            children: [
              ResponsiveSplit(
                first: StaggeredAppear(index: 0, child: scenarios),
                second: StaggeredAppear(index: 1, child: last),
                firstFlex: 4,
                secondFlex: 7,
              ),
            ],
          ),
        );
      },
    );
  }

  static Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text.rich(TextSpan(children: [
          TextSpan(
              text: '$k: ',
              style: StageText.body(14, color: StageColors.textSecondary)),
          TextSpan(text: v, style: StageText.body(14, weight: 600)),
        ])),
      );
}

class _Block extends StatelessWidget {
  const _Block({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(title, style: StageText.body(14.5, weight: 600)),
        trailing: IconButton(
          tooltip: 'Скопировать',
          icon: const Icon(Icons.copy_rounded, size: 18),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Скопировано')));
            }
          },
        ),
        children: [
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 420),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: StageColors.backgroundDeep,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontFamilyFallback: ['monospace', 'Manrope'],
                  fontSize: 12.5,
                  height: 1.4,
                  color: StageColors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
