import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../../app/app_scope.dart';
import '../../app/routes.dart';
import '../../data/criteria.dart';
import '../../theme/stage_theme.dart';
import '../format.dart';
import '../video_session.dart';
import '../widgets/common.dart';
import 'analysis_screen.dart';
import 'settings_screen.dart';
import 'shooting_guide_screen.dart';

const _videoTypes = XTypeGroup(
  label: 'Видео',
  extensions: ['mp4', 'mov', 'm4v', '3gp', 'mkv', 'webm', 'avi'],
  mimeTypes: ['video/*'],
  uniformTypeIdentifiers: ['public.movie'],
);

/// Экран «Видео» (spec 8б.2): выбор файла, превью, длительность, приватность.
class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, required this.dance});

  static const routeName = 'video';

  final Dance dance;

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  VideoSession? _session;
  VideoPlayerController? _player;
  bool _picking = false;
  bool _checking = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_session != null) return;
    final session = VideoSession(
      dance: widget.dance,
      tempStorage: AppScope.of(context).tempStorage,
    );
    session.addListener(_onSessionChanged);
    session.onChooseOther = _pick;
    _session = session;
  }

  @override
  void dispose() {
    _player?.dispose();
    _session!
      ..removeListener(_onSessionChanged)
      ..release();
    super.dispose();
  }

  /// Видео могли освободить после успешного анализа — убираем превью.
  void _onSessionChanged() {
    if (!_session!.hasVideo && _player != null) {
      final p = _player;
      _player = null;
      p!.dispose();
    }
    if (mounted) setState(() {});
  }

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final file = await openFile(acceptedTypeGroups: const [_videoTypes]);
      if (file == null || !mounted) return;
      setState(() => _checking = true);
      final probe = await AppScope.of(context).preparer.probe(file.path);
      if (!mounted) return;
      await _player?.dispose();
      _player = null;
      await _session!.setVideo(file.path, file.name, probe);
      await _initPreview(file.path);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Не удалось открыть файл. Выберите другое видео.')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _picking = false;
          _checking = false;
        });
      }
    }
  }

  /// Превью — где платформа умеет (Android; Windows через video_player_win).
  Future<void> _initPreview(String path) async {
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
      await controller.setVolume(0.6);
      if (!mounted || _session!.path != path) {
        await controller.dispose();
        return;
      }
      setState(() => _player = controller);
    } catch (_) {
      await controller.dispose();
    }
  }

  void _start() {
    final session = _session!;
    _player?.pause();
    Navigator.of(context).push(stageRoute(
      AnalysisScreen(session: session),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final settings = services.settings;
    final accent = DanceAccent.of(widget.dance.style);
    final session = _session!;
    final probe = session.probe;
    final noAudio = probe?.hasAudio == false;

    final picker = _PickerCard(
      accent: accent,
      session: session,
      player: _player,
      busy: _picking || _checking,
      onPick: _pick,
    );

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (session.hasVideo) ...[
          StaggeredAppear(
            index: 0,
            child: GlowCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(session.name ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: StageText.body(15, weight: 600)),
                  const SizedBox(height: 12),
                  _InfoRow(
                    icon: Icons.schedule_rounded,
                    label: 'Длительность',
                    value: formatDuration(probe?.durationSec ??
                        _player?.value.duration.inMilliseconds.toDouble()
                            .let((ms) => ms > 0 ? ms / 1000 : null)),
                  ),
                  _InfoRow(
                    icon: noAudio
                        ? Icons.volume_off_rounded
                        : Icons.music_note_rounded,
                    label: 'Звук',
                    value: switch (probe?.hasAudio) {
                      true => 'есть',
                      false => 'нет',
                      null => 'проверится при анализе',
                    },
                    color: noAudio ? StageColors.poor : null,
                  ),
                ],
              ),
            ),
          ),
          if (noAudio) ...[
            const SizedBox(height: 12),
            _Notice(
              icon: Icons.volume_off_rounded,
              color: StageColors.poor,
              text: 'В видео нет звука. Для оценки нужна музыка. '
                  'Выберите видео со звуком.',
            ),
          ],
          const SizedBox(height: 12),
        ],
        if (!settings.isConfigured) ...[
          _Notice(
            icon: Icons.auto_awesome_rounded,
            color: StageColors.spotlight,
            text: 'ИИ не настроен. Сейчас оценка работает в демо-режиме — '
                'чтобы подключить ИИ, откройте настройки.',
            action: TextButton(
              onPressed: () =>
                  Navigator.of(context).push(stageRoute(const SettingsScreen())),
              child: const Text('Настройки'),
            ),
          ),
          const SizedBox(height: 12),
        ],
        _Notice(
          icon: Icons.lock_outline_rounded,
          color: StageColors.textSecondary,
          text: 'Видео отправляется выбранному ИИ-провайдеру. На бесплатных '
              'тарифах провайдер может использовать данные. В приложении '
              'видео не сохраняется.',
        ),
        const SizedBox(height: 20),
        PrimaryButton(
          label: 'Оценить',
          icon: Icons.auto_graph_rounded,
          accent: accent,
          expand: true,
          onPressed: session.hasVideo && !noAudio && !_checking ? _start : null,
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            onPressed: () => Navigator.of(context)
                .push(stageRoute(const ShootingGuideScreen())),
            icon: const Icon(Icons.videocam_outlined, size: 18),
            label: const Text('Как снимать'),
          ),
        ),
      ],
    );

    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => StageScaffold(
        accent: accent,
        title: null,
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          children: [
            Hero(
              tag: 'dance-title-${widget.dance.id}',
              child: Material(
                type: MaterialType.transparency,
                child: Text(widget.dance.nameRu,
                    style: StageText.display(isWide(context) ? 40 : 32)),
              ),
            ),
            const SizedBox(height: 4),
            Text('Загрузите видео пары со звуком',
                style: StageText.body(15, color: StageColors.textSecondary)),
            const SizedBox(height: 20),
            ResponsiveSplit(first: picker, second: info, firstFlex: 6, secondFlex: 5),
          ],
        ),
      ),
    );
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

class _PickerCard extends StatelessWidget {
  const _PickerCard({
    required this.accent,
    required this.session,
    required this.player,
    required this.busy,
    required this.onPick,
  });

  final DanceAccent accent;
  final VideoSession session;
  final VideoPlayerController? player;
  final bool busy;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final p = player;
    Widget content;
    if (busy) {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
                strokeWidth: 2.5, color: accent.primary),
          ),
          const SizedBox(height: 14),
          Text('Проверяю видео…',
              style: StageText.body(14, color: StageColors.textSecondary)),
        ],
      );
    } else if (p != null && p.value.isInitialized) {
      content = _Preview(controller: p, accent: accent);
    } else if (session.hasVideo) {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.movie_outlined, size: 44, color: accent.primary),
          const SizedBox(height: 10),
          Text('Видео выбрано',
              style: StageText.body(15, weight: 600)),
          const SizedBox(height: 4),
          Text('Превью на этой платформе недоступно',
              style: StageText.body(13, color: StageColors.textMuted)),
        ],
      );
    } else {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: accent.gradient,
              boxShadow: [
                BoxShadow(
                    color: accent.glow.withValues(alpha: 0.55), blurRadius: 30),
              ],
            ),
            child: const Icon(Icons.video_library_rounded,
                size: 32, color: StageColors.backgroundDeep),
          ),
          const SizedBox(height: 16),
          Text('Выбрать видео', style: StageText.display(22)),
          const SizedBox(height: 6),
          Text('Тренировка или турнир, обязательно со звуком',
              textAlign: TextAlign.center,
              style: StageText.body(13.5, color: StageColors.textSecondary)),
        ],
      );
    }

    return GlowCard(
      accent: accent,
      glow: session.hasVideo ? 0 : 0.3,
      onTap: busy || (p != null && p.value.isInitialized) ? null : onPick,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 10,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              child: KeyedSubtree(
                key: ValueKey('${session.path}-$busy-${p != null}'),
                child: content,
              ),
            ),
          ),
          if (session.hasVideo && !busy) ...[
            const SizedBox(height: 10),
            Center(
              child: GhostButton(
                label: 'Выбрать другое видео',
                icon: Icons.swap_horiz_rounded,
                onPressed: onPick,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.controller, required this.accent});

  final VideoPlayerController controller;
  final DanceAccent accent;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          Center(
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: controller,
            builder: (context, v, _) => Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => v.isPlaying ? controller.pause() : controller.play(),
                child: AnimatedOpacity(
                  opacity: v.isPlaying ? 0 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: Center(
                    child: Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withValues(alpha: 0.45),
                        border: Border.all(color: accent.primary, width: 1.5),
                      ),
                      child: Icon(Icons.play_arrow_rounded,
                          size: 34, color: accent.primary),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: VideoProgressIndicator(
              controller,
              allowScrubbing: true,
              colors: VideoProgressColors(
                playedColor: accent.primary,
                bufferedColor: Colors.white24,
                backgroundColor: Colors.white10,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color ?? StageColors.textSecondary),
            const SizedBox(width: 10),
            Text('$label: ',
                style: StageText.body(14, color: StageColors.textSecondary)),
            Expanded(
              child: Text(value,
                  style: StageText.body(14, weight: 600, color: color)),
            ),
          ],
        ),
      );
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.text,
    this.action,
  });

  final IconData icon;
  final Color color;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text, style: StageText.body(13.5)),
                  if (action != null)
                    Align(alignment: Alignment.centerLeft, child: action),
                ],
              ),
            ),
          ],
        ),
      );
}
