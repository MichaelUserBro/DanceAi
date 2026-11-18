import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../analysis/ai_provider.dart';
import '../../analysis/analysis_export.dart';
import '../../analysis/analysis_pipeline.dart';
import '../../analysis/music/music_analyzer.dart';
import '../../platform/file_saver.dart';
import '../../settings/settings_store.dart';
import '../../analysis/prompt_builder.dart';
import '../../analysis/stub_ai_provider.dart';
import '../../analysis/video_preparer.dart';
import '../../app/app_scope.dart';
import '../../theme/stage_theme.dart';
import '../format.dart';
import '../widgets/common.dart';

/// «Для разработчика» (spec 7.8): демо-режим и сценарий заглушки, частота
/// кадров видеорежима, сведения о последнем анализе (подготовка, запросы
/// к ИИ, токены, повтор, сырые ответы), «Сохранить JSON». Ключа здесь нет.
class DeveloperScreen extends StatelessWidget {
  const DeveloperScreen({super.key, this.saver});

  /// Для тестов; по умолчанию — системный диалог сохранения.
  final FileSaver? saver;

  Future<void> _save(BuildContext context, AnalysisTrace trace) async {
    final messenger = ScaffoldMessenger.of(context);
    final data = AppScope.of(context).data;
    try {
      final ok = await (saver ?? FileSaver.platform()).save(
        name: analysisExportFileName(trace),
        bytes: utf8.encode(analysisExportText(trace, data)),
      );
      if (ok) {
        messenger.showSnackBar(const SnackBar(content: Text('JSON сохранён')));
      }
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Не удалось сохранить файл')));
    }
  }

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
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Демо-режим (без ИИ)',
                    style: StageText.body(15.5, weight: 700)),
                subtitle: Text(
                  'Анализ через заглушку: без ключа и без расхода лимитов. '
                  'Подготовка видео — настоящая.',
                  style: StageText.body(12.5, color: StageColors.textMuted),
                ),
                value: settings.demoMode,
                onChanged: settings.setDemoMode,
              ),
              const SizedBox(height: 12),
              Text('Частота кадров видеорежима', style: StageText.display(20)),
              const SizedBox(height: 4),
              Text(
                'С какой частотой модель смотрит видео целиком — там, где API '
                'это позволяет (Gemini: videoMetadata.fps). Для проверки, '
                'влияет ли частота на оценку работы ног.',
                style: StageText.body(13, color: StageColors.textMuted),
              ),
              const SizedBox(height: 8),
              SegmentedButton<double>(
                segments: [
                  for (final f in SettingsStore.videoFpsChoices)
                    ButtonSegment(
                        value: f, label: Text('${f.round()} кадр/с')),
                ],
                selected: {settings.videoFps},
                onSelectionChanged: (v) => settings.setVideoFps(v.first),
              ),
              const SizedBox(height: 18),
              Text('Уровень размышления (Gemini)',
                  style: StageText.display(20)),
              const SizedBox(height: 4),
              Text(
                'thinkingConfig.thinkingLevel — для сравнения качества на '
                'эталонном наборе. «Модель» — по умолчанию модели.',
                style: StageText.body(13, color: StageColors.textMuted),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: [
                  const ButtonSegment(value: '', label: Text('Модель')),
                  for (final l in SettingsStore.thinkingLevels)
                    ButtonSegment(value: l, label: Text(l)),
                ],
                selected: {settings.thinkingLevel ?? ''},
                onSelectionChanged: (v) => settings
                    .setThinkingLevel(v.first.isEmpty ? null : v.first),
              ),
              const SizedBox(height: 18),
              Text('Сценарий заглушки ИИ', style: StageText.display(20)),
              const SizedBox(height: 4),
              Text(
                settings.demoMode
                    ? 'Что вернёт заглушка при следующем анализе'
                    : 'Действует в демо-режиме',
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
                  _kv('Провайдер', trace.demo
                      ? 'демо-режим (заглушка)'
                      : '${trace.providerName}'),
                  if (!trace.demo) _kv('Модель', '${trace.model}'),
                  if (trace.answeredModel != null &&
                      trace.answeredModel != trace.model)
                    _kv('Ответила модель', '${trace.answeredModel}'),
                  if (trace.useFallbackModels != null)
                    _kv('Запасные модели',
                        trace.useFallbackModels! ? 'включены' : 'выключены'),
                  _kv('Способ подачи', _modeText(trace)),
                  if (trace.thinkingLevel != null)
                    _kv('Уровень размышления', trace.thinkingLevel!),
                  if (trace.maxFramesSetting != null)
                    _kv('Максимум кадров (настройка)',
                        '${trace.maxFramesSetting}'),
                  _kv('Ответов ИИ', '${trace.responses.length}'),
                  _kv(
                      'Повторный запрос',
                      !trace.retried
                          ? 'нет'
                          : trace.attempts.any(
                                  (a) => a.reason == AttemptReason.invalidResponse)
                              ? 'был (первый ответ не прошёл проверку)'
                              : 'был (перегрузка или запасная модель)'),
                  if (trace.precheck != null)
                    _kv('Предварительная проверка', _precheck(trace.precheck!)),
                  if (trace.upload != null)
                    _kv('Материал', _upload(trace)),
                  for (final (i, a) in trace.attempts.indexed)
                    _kv('Запрос №${i + 1}', _attempt(a)),
                  for (final n in trace.chainNotes) _kv('Цепочка', n),
                  if (trace.aiTime != null)
                    _kv('Обращение к ИИ (потолок)', _secs(trace.aiTime)),
                  if (trace.totalTime != null)
                    _kv('Всего до отчёта', _secs(trace.totalTime)),
                  if (trace.failure != null) _kv('Итог', trace.failure!),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GhostButton(
                      label: 'Сохранить JSON',
                      icon: Icons.save_alt_rounded,
                      onPressed: () => _save(context, trace),
                    ),
                  ),
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

  static String _modeText(AnalysisTrace t) {
    if (t.mode != SubmissionMode.video) return 'кадры';
    final fps = t.videoFps;
    return fps == null
        ? 'видео целиком'
        : 'видео целиком, модель смотрит ${fps.round()} кадр/с';
  }

  static String _secs(Duration? d) =>
      d == null
          ? '—'
          : '${(d.inMilliseconds / 1000).toStringAsFixed(1).replaceAll('.', ',')} с';

  static String _precheck(PrecheckResult p) => [
        p.request,
        if (p.status != null) 'HTTP ${p.status}',
        _secs(p.time),
        if (p.error != null) 'ошибка: ${p.error!.kind.name}',
      ].join(' · ');

  static String _upload(AnalysisTrace t) {
    final u = t.upload!;
    return [
      switch (u.mode) {
        UploadMode.fileApi => 'File API, один раз на анализ',
        UploadMode.inline => 'в каждом запросе',
        UploadMode.inlineFallback => 'в каждом запросе (загрузка не удалась)',
      },
      if (u.bytes != null) _size(u.bytes!),
      if (u.uploadTime != null) 'загрузка ${_secs(u.uploadTime)}',
      if (u.activeWait != null) 'ожидание ACTIVE ${_secs(u.activeWait)}',
      ...u.notes,
      ...t.uploadNotes,
    ].join(' · ');
  }

  static String _attempt(AiAttempt a) {
    final u = a.usage;
    final tokens = u == null
        ? null
        : 'токены: вход ${u.inputTokens ?? '—'}, выход ${u.outputTokens ?? '—'}'
            '${u.thinkingTokens == null ? '' : ', размышление ${u.thinkingTokens}'}';
    final d = a.diag;
    return [
      if (a.model != null) 'модель ${a.model}',
      if (a.reason != AttemptReason.first) 'причина: ${a.reason.name}',
      if (a.pause > Duration.zero) 'пауза ${_secs(a.pause)}',
      if (a.sentBytes != null) 'отправлено ${_size(a.sentBytes!)}',
      if (d?.status != null) 'HTTP ${d!.status}',
      if (d?.headersTime != null) 'заголовки ${_secs(d!.headersTime)}',
      if (d?.firstByteTime != null) 'первый байт ${_secs(d!.firstByteTime)}',
      if (d?.errorSource != null) 'ошибка из ${d!.errorSource!.name}',
      if (a.sendTime != null) 'отправка ${_secs(a.sendTime)}',
      'до ответа ${_secs(a.totalTime)}',
      ?tokens,
      if (a.finishReason != null) 'завершение ${a.finishReason}',
      ...a.notes,
      if (a.quota != null) 'квота: ${a.quota == 'day' ? 'дневная' : 'поминутная'}',
      if (a.error != null) 'ошибка: ${a.error}',
    ].join(' · ');
  }

  static String _size(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} МБ'
      : '${(bytes / 1024).toStringAsFixed(0)} КБ';

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
    PrepareStage.compressingVideo: 'сжатие видео',
    PrepareStage.analyzingMusic: 'звук и музыка',
  };

  static String _num(double? v, int decimals) =>
      PromptBuilder.formatNumber(v, decimals: decimals).replaceAll('.', ',');

  static String _levelRu(MusicConfidence? l) => switch (l) {
        MusicConfidence.high => 'высокая',
        MusicConfidence.medium => 'средняя',
        MusicConfidence.low => 'низкая',
        null => '—',
      };

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
        if (d.lightVideoBytes != null)
          DeveloperScreen._kv(
            'Видео для отправки',
            '${DeveloperScreen._size(d.lightVideoBytes!)}, '
                '${d.lightVideoWidth}×${d.lightVideoHeight}, ${d.lightVideoCodec}',
          )
        else
          DeveloperScreen._kv('Кадров', frames),
        DeveloperScreen._kv(
          'Уровень звука',
          d.audioRmsDb == null
              ? '—'
              : 'средний ${_num(d.audioRmsDb, 1)} дБ, '
                  'пик ${_num(d.audioPeakDb, 1)} дБ',
        ),
        DeveloperScreen._kv(
          'Темп',
          d.bpm == null
              ? 'не определён'
              : '${_num(d.bpm, 1)} BPM, уверенность '
                  '${_num(d.musicConfidence, 2)} (${_levelRu(d.musicLevel)})',
        ),
        if (d.musicPeriodicity != null)
          DeveloperScreen._kv(
            'Ритм',
            'периодичность ${_num(d.musicPeriodicity, 3)} '
                '(нужно от ${_num(MusicAnalyzer.minPeriodicity, 3)}), '
                'темп совпал в ${d.musicAgreement == null ? '—' : '${(d.musicAgreement! * 100).round()} %'} '
                'частей записи',
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
