import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../analysis/adapter_registry.dart';
import '../../analysis/analysis_failure.dart';
import '../../analysis/analysis_pipeline.dart';
import '../../analysis/cancel_token.dart';
import '../../app/app_scope.dart';
import '../../app/routes.dart';
import '../../report/report.dart';
import '../../theme/stage_theme.dart';
import '../video_session.dart';
import '../widgets/common.dart';
import 'error_screen.dart';
import 'report_screen.dart';
import 'warning_screen.dart';

/// Экран анализа (spec 8б.3): живое ожидание с этапами, прогресс, отмена.
class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen(
      {super.key, required this.session, this.forceFrames = false});

  final VideoSession session;

  /// «Отправить кадрами» после ошибки режима видео.
  final bool forceFrames;

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen>
    with SingleTickerProviderStateMixin {
  final _cancel = CancelToken();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  final _elapsed = Stopwatch();
  Timer? _ticker;

  AnalysisStage _stage = AnalysisStage.checkingVideo;
  final _done = <AnalysisStage>{};
  bool _retry = false;
  AttemptNotice? _notice;
  bool _started = false;
  bool _demo = false;
  bool _videoMode = false;
  bool _processingSeen = false;
  double? _fraction;
  int? _received;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MediaQuery.of(context).disableAnimations && !_pulse.isAnimating) {
      _pulse.repeat();
    }
    if (!_started) {
      _started = true;
      _run();
    }
  }

  @override
  void dispose() {
    _cancel.cancel();
    _ticker?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final services = AppScope.of(context);
    final session = widget.session;
    final dance = session.dance;
    final path = session.path;
    final navigator = Navigator.of(context);
    if (path == null) {
      navigator.pop();
      return;
    }
    _elapsed.start();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });

    // Сведения прошлого анализа (в т. ч. превью кадров) больше не храним.
    final trace = AnalysisTrace();
    services.dev.record(trace);
    final settings = services.settings;
    setState(() {
      _demo = settings.demoMode;
      _videoMode = !widget.forceFrames && settings.wantVideo;
    });
    try {
      final pipeline = await services.createPipeline();
      if (mounted) {
        setState(() => _videoMode = _videoMode &&
            pipeline.provider.capabilities.supportsVideo);
      }
      final providerId = settings.provider?.id;
      final result = await pipeline.run(
        dance: dance,
        videoPath: path,
        wantVideo: settings.wantVideo,
        forceFrames: widget.forceFrames,
        videoFps: settings.videoFps,
        thinkingLevel: settings.thinkingLevel,
        maxFrames: settings.demoMode || providerId == null
            ? null
            : settings.maxFramesFor(providerId),
        cancel: _cancel,
        trace: trace,
        onProgress: _onProgress,
      );
      services.dev.record(trace);
      // Видео больше не нужно — удаляем копию сразу после анализа.
      await session.release();
      if (!mounted) return;
      final report = result.report;
      navigator.pushReplacement(stageRoute(
        report.videoAssessment.status == VideoStatus.ok
            ? ReportScreen(
                report: report,
                dance: dance,
                session: session,
                fallbackModel: result.fallbackModel)
            : WarningScreen(
                report: report,
                dance: dance,
                session: session,
                fallbackModel: result.fallbackModel),
      ));
    } on AnalysisCancelled {
      services.dev.record(trace);
    } on AnalysisFailure catch (failure) {
      services.dev.record(trace);
      if (!mounted) return;
      navigator.pushReplacement(stageRoute(
        ErrorScreen(failure: failure, session: session),
      ));
    }
  }

  void _onProgress(AnalysisProgress p) {
    if (!mounted) return;
    setState(() {
      final order = AnalysisStage.values;
      for (final s in order.take(p.stage.index)) {
        _done.add(s);
      }
      if (p.fraction == 1) _done.add(p.stage);
      if (p.stage == AnalysisStage.processing) _processingSeen = true;
      _stage = p.stage;
      _fraction = p.fraction;
      _received = p.receivedBytes;
      _retry = p.isRetry;
      if (p.notice != null) _notice = p.notice;
    });
  }

  /// «Отправка 45%» — где долю загрузки можно измерить.
  String _stageLabel() {
    final f = _fraction;
    if ((_stage == AnalysisStage.sending ||
            _stage == AnalysisStage.compressingVideo) &&
        f != null &&
        f > 0 &&
        f < 1) {
      return '${_stage.labelRu} ${(f * 100).round()}%';
    }
    final got = _received;
    if (_stage == AnalysisStage.analyzing && got != null && got > 0) {
      // Потоковая отдача: ИИ уже пишет отчёт.
      final kb = got / 1024;
      final shown = kb < 10
          ? kb.toStringAsFixed(1).replaceAll('.', ',')
          : '${kb.round()}';
      return 'ИИ пишет отчёт · $shown КБ';
    }
    return _stage.labelRu;
  }

  void _cancelAndClose() {
    _cancel.cancel();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final dance = widget.session.dance;
    final accent = DanceAccent.of(dance.style);
    // Этапы этого способа подачи: кадры или видео целиком.
    final stages = [
      for (final s in AnalysisStage.values)
        if (switch (s) {
          AnalysisStage.compressingVideo => _videoMode,
          AnalysisStage.extractingFrames => !_videoMode,
          AnalysisStage.processing => _processingSeen,
          _ => true,
        })
          s,
    ];
    final progress =
        (stages.where(_done.contains).length +
                (_done.contains(_stage) ? 0 : 0.5)) /
            stages.length;
    final wide = isWide(context);

    final visual = _LiveVisual(
      pulse: _pulse,
      accent: accent,
      title: dance.nameRu,
      subtitle: _notice?.nextModel != null
          ? 'Запасная модель'
          : _retry || _notice != null
              ? 'Повторный запрос'
              : _stageLabel(),
    );

    final steps = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_demo || !AdapterRegistry.realAdaptersAvailable)
          Align(
            alignment: Alignment.centerLeft,
            child: Pill(
              label: 'Демо-режим: без ИИ',
              color: StageColors.spotlight,
            ),
          ),
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: progress),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => LinearProgressIndicator(
              value: v,
              minHeight: 5,
              color: accent.primary,
              backgroundColor: StageColors.surfaceHigh,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
            'Прошло ${_elapsed.elapsed.inSeconds} с · анализ может занять '
            'до $analysisTimeLimitRu',
            style: StageText.label(12, color: StageColors.textMuted)),
        const SizedBox(height: 18),
        for (var i = 0; i < stages.length; i++)
          _StageRow(
            stage: stages[i],
            state: _done.contains(stages[i])
                ? _StepState.done
                : stages[i] == _stage
                    ? _StepState.active
                    : _StepState.pending,
            accent: accent,
          ),
        if (_notice != null) ...[
          const SizedBox(height: 8),
          Text(
            noticeText(_notice!),
            style: StageText.body(13, color: StageColors.partial),
          ),
        ],
        const SizedBox(height: 24),
        Center(
          child: GhostButton(
            label: 'Отменить',
            icon: Icons.close_rounded,
            onPressed: _cancelAndClose,
          ),
        ),
      ],
    );

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _cancel.cancel();
      },
      child: StageScaffold(
        accent: accent,
        intensity: 1.25,
        maxWidth: 1000,
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          children: [
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: visual),
                  const SizedBox(width: 32),
                  Expanded(child: steps),
                ],
              )
            else ...[
              SizedBox(height: 280, child: visual),
              const SizedBox(height: 12),
              steps,
            ],
          ],
        ),
      ),
    );
  }
}

enum _StepState { pending, active, done }

class _StageRow extends StatelessWidget {
  const _StageRow({
    required this.stage,
    required this.state,
    required this.accent,
  });

  final AnalysisStage stage;
  final _StepState state;
  final DanceAccent accent;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      _StepState.done => StageColors.good,
      _StepState.active => accent.primary,
      _StepState.pending => StageColors.textMuted,
    };
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: state == _StepState.active
            ? accent.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        border: Border.all(
          color: state == _StepState.active
              ? accent.primary.withValues(alpha: 0.35)
              : Colors.transparent,
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: switch (state) {
                _StepState.done => const Icon(Icons.check_circle_rounded,
                    key: ValueKey('done'), size: 22, color: StageColors.good),
                _StepState.active => CircularProgressIndicator(
                    key: const ValueKey('active'),
                    strokeWidth: 2.2,
                    color: accent.primary),
                _StepState.pending => Icon(Icons.circle_outlined,
                    key: const ValueKey('pending'), size: 20, color: color),
              },
            ),
          ),
          const SizedBox(width: 14),
          Text(stage.labelRu,
              style: StageText.body(15,
                  weight: state == _StepState.active ? 700 : 500,
                  color: state == _StepState.pending
                      ? StageColors.textMuted
                      : StageColors.textPrimary)),
        ],
      ),
    );
  }
}

/// «Живой» центр экрана: пульсирующие кольца-прожекторы и эквалайзер,
/// как будто пара кружится в луче света.
class _LiveVisual extends StatelessWidget {
  const _LiveVisual({
    required this.pulse,
    required this.accent,
    required this.title,
    required this.subtitle,
  });

  final Animation<double> pulse;
  final DanceAccent accent;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _PulsePainter(pulse: pulse, accent: accent),
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  textAlign: TextAlign.center, style: StageText.display(26)),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(subtitle,
                    key: ValueKey(subtitle),
                    style: StageText.label(14, color: accent.secondary)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PulsePainter extends CustomPainter {
  _PulsePainter({required this.pulse, required this.accent})
      : super(repaint: pulse);

  final Animation<double> pulse;
  final DanceAccent accent;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final t = pulse.value;

    // Расходящиеся кольца.
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1.0;
      final radius = r * (0.38 + 0.55 * phase);
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = accent.primary.withValues(alpha: 0.45 * (1 - phase)),
      );
    }

    // Мягкое ядро света.
    canvas.drawCircle(
      c,
      r * 0.42,
      Paint()
        ..shader = RadialGradient(colors: [
          accent.glow.withValues(alpha: 0.35),
          accent.glow.withValues(alpha: 0),
        ]).createShader(Rect.fromCircle(center: c, radius: r * 0.42)),
    );

    // Эквалайзер по кругу — «музыка».
    const bars = 48;
    final angleShift = t * 2 * math.pi;
    final barPaint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.4;
    for (var i = 0; i < bars; i++) {
      final a = 2 * math.pi * i / bars;
      final wave = (math.sin(a * 3 + angleShift * 2) +
              math.sin(a * 5 - angleShift * 3)) /
          4 +
          0.5;
      final inner = r * 0.47;
      final outer = inner + r * (0.04 + 0.12 * wave);
      final dir = Offset(math.cos(a + angleShift / 4), math.sin(a + angleShift / 4));
      barPaint.color = Color.lerp(accent.primary, accent.secondary, wave)!
          .withValues(alpha: 0.75);
      canvas.drawLine(c + dir * inner, c + dir * outer, barPaint);
    }

    // Две «точки-партнёра», кружащиеся по орбите.
    final orbit = r * 0.36;
    final ang = t * 2 * math.pi;
    for (final (shift, color) in [
      (0.0, StageColors.leader),
      (math.pi, StageColors.follower),
    ]) {
      final p = c + Offset(math.cos(ang + shift), math.sin(ang + shift)) * orbit;
      canvas.drawCircle(p, 9, Paint()..color = color.withValues(alpha: 0.25));
      canvas.drawCircle(p, 4.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.accent != accent;
}

/// Строка экрана анализа о повторе или запасной модели (spec 8б.3).
String noticeText(AttemptNotice n) {
  final next = n.nextModel;
  if (next == null) {
    final pause = n.pause;
    return switch (n.reason) {
      AttemptReason.invalidResponse =>
        'Первый ответ ИИ не прошёл проверку — отправлен повторный запрос.',
      AttemptReason.rateLimit => 'Лимит запросов модели ${n.model} в минуту — '
          'жду${pause == null ? '' : ' ${pause.inSeconds} с'} и пробую ещё раз…',
      _ => 'Сервер ИИ перегружен, пробую ещё раз…',
    };
  }
  return switch (n.reason) {
    AttemptReason.rateLimit =>
      'У модели ${n.model} исчерпан лимит запросов, пробую запасную: $next…',
    AttemptReason.modelUnavailable =>
      'Модель ${n.model} недоступна, пробую запасную: $next…',
    AttemptReason.noResponse =>
      'Модель ${n.model} не отвечает, пробую запасную: $next…',
    _ => 'Модель ${n.model} перегружена, пробую запасную: $next…',
  };
}
