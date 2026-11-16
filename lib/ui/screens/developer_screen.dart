import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../analysis/prompt_builder.dart';
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
              Text(
                'Что вернёт заглушка при следующем анализе',
                style: StageText.body(13, color: StageColors.textMuted),
              ),
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
              if (trace == null)
                Text(
                  'Пока не было анализа. Запустите оценку любого видео — '
                  'здесь появятся подготовка видео, собранный промпт '
                  'и анализ музыки.',
                  style: StageText.body(14, color: StageColors.textMuted),
                )
              else ...[
                _PrepareInfo(d: trace.prepare),
                if (trace.prompt != null) ...[
                  const SizedBox(height: 16),
                  Text('Запрос к ИИ', style: StageText.body(15.5, weight: 700)),
                  const SizedBox(height: 8),
                  _kv(
                    'Способ подачи',
                    trace.mode == SubmissionMode.video
                        ? 'видео целиком'
                        : 'кадры',
                  ),
                  _kv('Ответов ИИ', '${trace.responses.length}'),
                  const SizedBox(height: 12),
                  _Block(title: 'Системный промпт', text: trace.prompt!.system),
                  _Block(title: 'Запрос', text: trace.prompt!.user),
                  for (var i = 0; i < trace.responses.length; i++)
                    _Block(
                      title: 'Ответ ИИ №${i + 1}',
                      text: trace.responses[i],
                    ),
                  for (var i = 0; i < trace.problems.length; i++)
                    _Block(
                      title: 'Ошибки проверки ответа №${i + 1}',
                      text: trace.problems[i].join('\n'),
                    ),
                ],
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
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$k: ',
            style: StageText.body(14, color: StageColors.textSecondary),
          ),
          TextSpan(text: v, style: StageText.body(14, weight: 600)),
        ],
      ),
    ),
  );
}

/// Подготовка последнего видео: длительность, звук, кадры, превью,
/// анализ музыки, время стадий. Превью — только в памяти.
class _PrepareInfo extends StatelessWidget {
  const _PrepareInfo({required this.d});

  final PrepareDiagnostics d;

  static const _stageNames = {
    PrepareStage.checkingVideo: 'проверка',
    PrepareStage.extractingFrames: 'кадры',
    PrepareStage.analyzingMusic: 'звук и музыка',
  };

  static String _num(double? v, int decimals) =>
      PromptBuilder.formatNumber(v, decimals: decimals).replaceAll('.', ',');

  static String _sec(Duration x) => '${_num(x.inMilliseconds / 1000, 1)} с';

  @override
  Widget build(BuildContext context) {
    final total = d.stageTimes.values.fold(Duration.zero, (a, b) => a + b);
    final frames = d.frameCount == null
        ? '—'
        : '${d.frameCount}, ${_num(d.actualFps, 2)} кадр/с'
              '${d.thinned ? ' (задано ${_num(d.requestedFps, 2)}, снижено под лимит)' : ''}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Подготовка видео', style: StageText.body(15.5, weight: 700)),
        const SizedBox(height: 8),
        DeveloperScreen._kv('Длительность', formatDuration(d.durationSec)),
        DeveloperScreen._kv('Звук', switch (d.hasAudio) {
          true => 'есть',
          false => 'нет',
          null => '—',
        }),
        if (d.width != null)
          DeveloperScreen._kv('Исходный размер', '${d.width}×${d.height}'),
        DeveloperScreen._kv('Кадров', frames),
        DeveloperScreen._kv(
          'Темп',
          d.bpm == null
              ? 'не определён'
              : '${_num(d.bpm, 1)} BPM, уверенность ${_num(d.musicConfidence, 2)}',
        ),
        if (d.stageTimes.isNotEmpty)
          DeveloperScreen._kv(
            'Время',
            [
              for (final e in d.stageTimes.entries)
                '${_stageNames[e.key]} ${_sec(e.value)}',
              'всего ${_sec(total)}',
            ].join(' · '),
          ),
        for (final n in d.notes)
          Text('• $n', style: StageText.body(13, color: StageColors.textMuted)),
        if (d.previews.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in d.previews)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        p.image,
                        height: 90,
                        gaplessPlayback: true,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      p.label,
                      style: StageText.body(
                        12,
                        color: StageColors.textSecondary,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
        if (d.musicText != null) ...[
          const SizedBox(height: 8),
          _Block(title: 'Анализ музыки', text: d.musicText!),
        ],
      ],
    );
  }
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
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Скопировано')));
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
