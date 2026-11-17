import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../data/criteria.dart';
import '../../report/overall_score.dart';
import '../../report/report.dart';
import '../../report/report_labels.dart';
import '../../theme/stage_theme.dart';
import '../format.dart';
import '../video_session.dart';
import '../widgets/common.dart';
import '../widgets/radar_chart.dart';

/// Краткий и подробный отчёт (spec 6, 8б.5).
class ReportScreen extends StatefulWidget {
  const ReportScreen({
    super.key,
    required this.report,
    required this.dance,
    required this.session,
    this.fallbackModel,
  });

  final DanceReport report;
  final Dance dance;
  final VideoSession session;

  /// Отчёт подготовила запасная модель (основная была перегружена).
  final String? fallbackModel;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  bool _detailed = false;

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context).data.criteria;
    final report = widget.report;
    final dance = widget.dance;
    final accent = DanceAccent.of(dance.style);
    final componentIds = [for (final c in catalog.components) c.id];
    final overall = overallScore(report, componentIds);

    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.fallbackModel != null) ...[
          FallbackNote(model: widget.fallbackModel!),
          const SizedBox(height: 12),
        ],
        StaggeredAppear(
          index: 0,
          child: _ScoreHero(
              report: report, overall: overall, accent: accent, dance: dance),
        ),
        const SizedBox(height: 16),
        StaggeredAppear(
          index: 1,
          child: GlowCard(
            accent: accent,
            child: RadarChart(
              axes: [for (final c in catalog.components) c.nameRu],
              series: [
                for (final who in [Who.couple, Who.leader, Who.follower])
                  if (who == Who.couple || report.hasPersonScores(who))
                    RadarSeries(
                      label: who.titleRu,
                      color: StageColors.who(who, accent),
                      filled: who == Who.couple,
                      marker: switch (who) {
                        Who.couple => RadarMarker.dot,
                        Who.leader => RadarMarker.diamond,
                        Who.follower => RadarMarker.ring,
                      },
                      lineOffset: switch (who) {
                        Who.couple => 0,
                        Who.leader => 2.5,
                        Who.follower => -2.5,
                      },
                      values: [
                        for (final id in componentIds) report.scores[id]!.of(who)
                      ],
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < catalog.components.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: StaggeredAppear(
              index: 2 + i,
              child: _ComponentCard(
                component: catalog.components[i],
                score: report.scores[catalog.components[i].id]!,
                accent: accent,
              ),
            ),
          ),
      ],
    );

    final mistakes = _detailed ? report.mistakes : report.keyMistakes;
    final right = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StaggeredAppear(
          index: 2,
          child: GlowCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Вывод', style: StageText.display(20)),
                const SizedBox(height: 10),
                Text(report.summary.overallComment,
                    style: StageText.body(15)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        StaggeredAppear(
          index: 3,
          child: GlowCard(
            accent: accent,
            glow: 0.25,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Над чем работать', style: StageText.display(20)),
                const SizedBox(height: 12),
                for (var i = 0; i < report.priorities.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 26,
                          height: 26,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: accent.gradient),
                          child: Text('${i + 1}',
                              style: StageText.label(13,
                                  weight: 800,
                                  color: StageColors.backgroundDeep)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(report.priorities[i],
                              style: StageText.body(15)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        StaggeredAppear(
          index: 4,
          child: _MistakesCard(
            mistakes: mistakes,
            title: _detailed ? 'Все ошибки' : 'Главные ошибки',
            total: report.mistakes.length,
            filterable: _detailed,
            dance: dance,
          ),
        ),
      ],
    );

    final header = Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 12,
      children: [
        Text(dance.nameRu, style: StageText.display(30)),
        SegmentedButton<bool>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: accent.primary.withValues(alpha: 0.2),
              selectedForegroundColor: accent.primary,
              foregroundColor: StageColors.textSecondary,
              side: const BorderSide(color: StageColors.outline),
              textStyle: StageText.label(13),
              visualDensity: VisualDensity.compact,
            ),
            segments: const [
              ButtonSegment(value: false, label: Text('Кратко')),
              ButtonSegment(value: true, label: Text('Подробно')),
            ],
            selected: {_detailed},
            onSelectionChanged: (s) => setState(() => _detailed = s.first),
          ),
      ],
    );

    return StageScaffold(
      accent: accent,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
        children: [
          header,
          const SizedBox(height: 18),
          ResponsiveSplit(first: left, second: right),
          AnimatedSize(
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _detailed
                ? _DetailedSections(report: report, dance: dance, accent: accent)
                : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: 28),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              PrimaryButton(
                label: 'Оценить другое видео',
                icon: Icons.video_library_rounded,
                accent: accent,
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.session.onChooseOther?.call();
                },
              ),
              GhostButton(
                label: 'К выбору танца',
                icon: Icons.home_outlined,
                onPressed: () =>
                    Navigator.of(context).popUntil((r) => r.isFirst),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScoreHero extends StatelessWidget {
  const _ScoreHero({
    required this.report,
    required this.overall,
    required this.accent,
    required this.dance,
  });

  final DanceReport report;
  final double overall;
  final DanceAccent accent;
  final Dance dance;

  @override
  Widget build(BuildContext context) {
    final status = report.videoAssessment.status;
    return GlowCard(
      accent: accent,
      glow: 0.5,
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Общая оценка',
                    style: StageText.label(13,
                        color: StageColors.textSecondary)),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    ShaderMask(
                      shaderCallback: (r) => accent.gradient.createShader(r),
                      child: AnimatedCounter(
                        value: overall,
                        decimals: 1,
                        style: StageText.display(64, weight: 800),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('из 10',
                        style: StageText.body(16,
                            color: StageColors.textMuted)),
                  ],
                ),
                const SizedBox(height: 4),
                Text('Среднее оценок пары по 4 компонентам',
                    style: StageText.body(12.5,
                        color: StageColors.textMuted)),
              ],
            ),
          ),
          if (status != VideoStatus.ok)
            Pill(
              label: status.labelRu,
              color: status == VideoStatus.unusable
                  ? StageColors.poor
                  : StageColors.partial,
            ),
        ],
      ),
    );
  }
}

class _ComponentCard extends StatelessWidget {
  const _ComponentCard({
    required this.component,
    required this.score,
    required this.accent,
  });

  final ScoreComponent component;
  final ComponentScore score;
  final DanceAccent accent;

  @override
  Widget build(BuildContext context) {
    final instant = MediaQuery.of(context).disableAnimations;
    return GlowCard(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(component.nameRu,
                    style: StageText.body(16, weight: 700)),
              ),
              AnimatedCounter(
                value: score.couple.toDouble(),
                style: StageText.display(28, color: accent.primary),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: instant ? score.couple / 10 : 0,
                  end: score.couple / 10),
              duration: instant
                  ? Duration.zero
                  : const Duration(milliseconds: 1200),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => Stack(
                children: [
                  Container(height: 6, color: StageColors.surfaceHigh),
                  FractionallySizedBox(
                    widthFactor: v,
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(gradient: accent.gradient),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (score.leader != null || score.follower != null) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 14,
              children: [
                if (score.leader != null)
                  _PersonScore(Who.leader, score.leader!, accent),
                if (score.follower != null)
                  _PersonScore(Who.follower, score.follower!, accent),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(score.comment,
              style: StageText.body(13.5, color: StageColors.textSecondary)),
        ],
      ),
    );
  }
}

class _PersonScore extends StatelessWidget {
  const _PersonScore(this.who, this.value, this.accent);

  final Who who;
  final int value;
  final DanceAccent accent;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
                color: StageColors.who(who, accent), shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text('${who.titleRu}: $value',
              style: StageText.label(12.5, color: StageColors.textSecondary)),
        ],
      );
}

class _MistakesCard extends StatefulWidget {
  const _MistakesCard({
    required this.mistakes,
    required this.title,
    required this.total,
    required this.filterable,
    required this.dance,
  });

  final List<Mistake> mistakes;
  final String title;
  final int total;
  final bool filterable;
  final Dance dance;

  @override
  State<_MistakesCard> createState() => _MistakesCardState();
}

class _MistakesCardState extends State<_MistakesCard> {
  Who? _who;

  @override
  Widget build(BuildContext context) {
    final list = widget.filterable && _who != null
        ? widget.mistakes.where((m) => m.who == _who).toList()
        : widget.mistakes;
    return GlowCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(widget.title, style: StageText.display(20))),
              if (!widget.filterable && widget.total > widget.mistakes.length)
                Text('${widget.mistakes.length} из ${widget.total}',
                    style: StageText.label(12, color: StageColors.textMuted)),
            ],
          ),
          if (widget.filterable) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final w in <Who?>[null, ...Who.values])
                  ChoiceChip(
                    label: Text(w == null ? 'Все' : w.titleRu),
                    selected: _who == w,
                    onSelected: (_) => setState(() => _who = w),
                    labelStyle: StageText.label(12.5),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          if (list.isEmpty)
            Text('Ошибок нет.',
                style: StageText.body(14, color: StageColors.textMuted)),
          for (final m in list) _MistakeRow(m, widget.dance),
        ],
      ),
    );
  }
}

class _MistakeRow extends StatelessWidget {
  const _MistakeRow(this.mistake, this.dance);

  final Mistake mistake;
  final Dance dance;

  @override
  Widget build(BuildContext context) {
    final figure = dance.figureById(mistake.figureId);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: StageColors.textPrimary.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border(
          left: BorderSide(
              color: StageColors.severity(mistake.severity), width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SeverityPill(mistake.severity),
              Text(mistake.who.titleRu,
                  style: StageText.label(12.5,
                      color: StageColors.textSecondary)),
              if (figure != null)
                Text('· ${figure.nameRu}',
                    style: StageText.label(12.5,
                        color: StageColors.textMuted)),
            ],
          ),
          const SizedBox(height: 6),
          Text(mistake.description, style: StageText.body(14.5)),
        ],
      ),
    );
  }
}

/// Разделы подробного отчёта.
class _DetailedSections extends StatelessWidget {
  const _DetailedSections({
    required this.report,
    required this.dance,
    required this.accent,
  });

  final DanceReport report;
  final Dance dance;
  final DanceAccent accent;

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context).data.criteria;
    final resultsById = {
      for (final r in report.criteriaResults) r.criterionId: r,
    };

    final criteriaCard = GlowCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Критерии', style: StageText.display(20)),
          for (final comp in catalog.components) ...[
            const SizedBox(height: 14),
            Text(comp.nameRu.toUpperCase(),
                style: StageText.label(12, weight: 700, color: accent.primary)),
            const SizedBox(height: 6),
            for (final c in catalog.criteriaFor(dance)
                .where((c) => c.componentId == comp.id))
              if (resultsById[c.id] case final r?)
                _CriterionRow(criterion: c, result: r),
          ],
        ],
      ),
    );

    final figuresCard = GlowCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Фигуры', style: StageText.display(20)),
          const SizedBox(height: 12),
          if (report.figures.isEmpty)
            Text('ИИ не распознал фигуры.',
                style: StageText.body(14, color: StageColors.textMuted)),
          for (final f in report.figures)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(f.nameRu, style: StageText.body(15, weight: 700)),
                      if (f.nameEn != null)
                        Text(f.nameEn!,
                            style: StageText.label(12.5,
                                color: StageColors.textMuted)),
                      Text('× ${f.count}',
                          style: StageText.label(12.5,
                              color: StageColors.textSecondary)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    VerdictPill(f.quality, dense: true),
                    Pill(
                      label: f.confidence.labelRu,
                      color: StageColors.textSecondary,
                      dense: true,
                    ),
                    if (f.figureId == null)
                      const Pill(
                        label: 'не из списка',
                        color: StageColors.spotlight,
                        dense: true,
                      ),
                  ]),
                  const SizedBox(height: 6),
                  Text(f.comment,
                      style: StageText.body(13.5,
                          color: StageColors.textSecondary)),
                ],
              ),
            ),
        ],
      ),
    );

    final people = [
      for (final who in Who.values)
        GlowCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                      color: StageColors.who(who, accent),
                      shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(who.titleRu, style: StageText.display(19)),
              ]),
              const SizedBox(height: 12),
              Text('Сильные стороны',
                  style: StageText.label(12.5, color: StageColors.good)),
              const SizedBox(height: 6),
              BulletList(report.summary.of(who).strengths,
                  color: StageColors.good),
              const SizedBox(height: 8),
              Text('Слабые стороны',
                  style: StageText.label(12.5, color: StageColors.poor)),
              const SizedBox(height: 6),
              BulletList(report.summary.of(who).weaknesses,
                  color: StageColors.poor),
            ],
          ),
        ),
    ];

    final va = report.videoAssessment;
    final observations = GlowCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Дополнительно', style: StageText.display(20)),
          const SizedBox(height: 10),
          BulletList(report.additionalObservations,
              empty: 'Дополнительных наблюдений нет.'),
          const SizedBox(height: 12),
          Text('О видео', style: StageText.label(13, color: accent.primary)),
          const SizedBox(height: 6),
          Text(
            'Видимость пары: ${va.quality.labelRu}. '
            'Музыкальность оценена ${va.musicSource.labelRu}.',
            style: StageText.body(14),
          ),
          const SizedBox(height: 4),
          Text('Кого оценил ИИ: ${va.coupleDescription}',
              style: StageText.body(14, color: StageColors.textSecondary)),
          if (va.issues.isNotEmpty) ...[
            const SizedBox(height: 8),
            BulletList(va.issues, color: StageColors.partial),
          ],
        ],
      ),
    );

    final wide = isWide(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionTitle('Подробный разбор',
              trailing: Text(
                countLabel(report.criteriaResults.length, 'критерий',
                    'критерия', 'критериев'),
                style: StageText.label(12.5, color: StageColors.textMuted),
              )),
          ResponsiveSplit(
            first: StaggeredAppear(index: 0, child: criteriaCard),
            second: StaggeredAppear(index: 1, child: figuresCard),
            firstFlex: 6,
            secondFlex: 5,
          ),
          const SizedBox(height: 24),
          const SectionTitle('Разбор по людям'),
          if (wide)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < people.length; i++) ...[
                    if (i > 0) const SizedBox(width: 16),
                    Expanded(
                        child: StaggeredAppear(index: 2 + i, child: people[i])),
                  ],
                ],
              ),
            )
          else
            for (var i = 0; i < people.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: StaggeredAppear(index: 2 + i, child: people[i]),
              ),
          const SizedBox(height: 24),
          StaggeredAppear(index: 5, child: observations),
        ],
      ),
    );
  }
}

class _CriterionRow extends StatelessWidget {
  const _CriterionRow({required this.criterion, required this.result});

  final Criterion criterion;
  final CriterionResult result;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(criterion.nameRu, style: StageText.body(14.5, weight: 600)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [
            VerdictPill(result.couple, prefix: 'пара', dense: true),
            if (result.leader != null)
              VerdictPill(result.leader!, prefix: 'партнёр', dense: true),
            if (result.follower != null)
              VerdictPill(result.follower!, prefix: 'партнёрша', dense: true),
          ]),
          const SizedBox(height: 4),
          Text(result.comment,
              style: StageText.body(13, color: StageColors.textSecondary)),
        ],
      ),
    );
  }
}

/// Спокойная строка: отчёт подготовила запасная модель (spec 8б.4).
class FallbackNote extends StatelessWidget {
  const FallbackNote({super.key, required this.model});

  final String model;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: StageColors.surfaceHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.swap_horiz_rounded,
                size: 18, color: StageColors.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Отчёт подготовила запасная модель $model '
                '(основная была перегружена)',
                style: StageText.body(13, color: StageColors.textMuted),
              ),
            ),
          ],
        ),
      );
}
