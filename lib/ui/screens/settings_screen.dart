import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../analysis/adapter_registry.dart';
import '../../analysis/ai_provider.dart';
import '../../analysis/cancel_token.dart';
import '../../app/app_scope.dart';
import '../../app/routes.dart';
import '../../data/providers_catalog.dart';
import '../../settings/settings_store.dart';
import '../../theme/stage_theme.dart';
import '../widgets/common.dart';
import 'developer_screen.dart';
import 'key_help_screen.dart';

/// Настройки (spec 8б.7).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final selected = settings.provider;
        final modeCard = _ModeCard();
        final providers = _ProviderList(settings: settings);
        final details = selected == null
            ? GlowCard(
                child: Text(
                  'Выберите провайдера ИИ — затем укажите модель и ключ API.',
                  style: StageText.body(14.5, color: StageColors.textSecondary),
                ),
              )
            : _ProviderDetails(
                key: ValueKey(selected.id),
                provider: selected,
                settings: settings,
              );

        return StageScaffold(
          title: 'Настройки',
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            children: [
              if (settings.demoMode ||
                  !AdapterRegistry.realAdaptersAvailable) ...[
                StaggeredAppear(
                  index: 0,
                  child: Pill(
                    label: 'Включён демо-режим — анализ идёт без ИИ '
                        '(выключается в «Для разработчика»)',
                    color: StageColors.spotlight,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              StaggeredAppear(index: 1, child: modeCard),
              const SizedBox(height: 20),
              ResponsiveSplit(
                firstFlex: 4,
                secondFlex: 6,
                first: StaggeredAppear(index: 2, child: providers),
                second: StaggeredAppear(index: 3, child: details),
              ),
              const SizedBox(height: 20),
              StaggeredAppear(
                index: 4,
                child: _NavCard(
                  icon: Icons.code_rounded,
                  title: 'Для разработчика',
                  subtitle: 'Демо-режим, подготовка видео, запросы к ИИ, '
                      'сохранение JSON',
                  onTap: () => Navigator.of(context)
                      .push(stageRoute(const DeveloperScreen())),
                ),
              ),
              const SizedBox(height: 12),
              StaggeredAppear(
                index: 5,
                child: _NavCard(
                  icon: Icons.gavel_rounded,
                  title: 'Лицензии',
                  subtitle: 'FFmpeg (LGPL), шрифты и библиотеки',
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'DanceAI',
                    applicationLegalese:
                        '© 2026 Mikle Klepak. Все права защищены.',
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NavCard extends StatelessWidget {
  const _NavCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlowCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          Icon(icon, color: StageColors.textSecondary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: StageText.body(15, weight: 700)),
                Text(subtitle,
                    style: StageText.body(13, color: StageColors.textMuted)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: StageColors.textMuted),
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final windows = Platform.isWindows;
    return GlowCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Режим ИИ', style: StageText.display(20)),
          const SizedBox(height: 12),
          _Choice(
            title: 'Внешний ИИ по API',
            subtitle: 'Видео анализирует выбранный провайдер по вашему ключу',
            selected: true,
            onTap: () {},
          ),
          const SizedBox(height: 8),
          _Choice(
            title: 'Своя модель',
            subtitle: windows
                ? 'Скоро: локальная модель на компьютере'
                : 'Скоро, только на Windows',
            selected: false,
            onTap: null,
            badge: 'скоро',
          ),
        ],
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;
  final String? badge;
  static const accent = StageColors.spotlight;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: selected
                  ? accent.withValues(alpha: 0.12)
                  : StageColors.textPrimary.withValues(alpha: 0.03),
              border: Border.all(
                  color: selected
                      ? accent.withValues(alpha: 0.6)
                      : StageColors.outline),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: selected ? accent : StageColors.textMuted,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: StageText.body(15, weight: 700)),
                      if (subtitle.isNotEmpty)
                        Text(subtitle,
                            style: StageText.body(12.5,
                                color: StageColors.textMuted)),
                    ],
                  ),
                ),
                if (badge != null) Pill(label: badge!, color: accent, dense: true),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProviderList extends StatelessWidget {
  const _ProviderList({required this.settings});

  final SettingsStore settings;

  @override
  Widget build(BuildContext context) {
    final all = settings.catalog.all;
    return GlowCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Провайдер', style: StageText.display(20)),
          const SizedBox(height: 4),
          Text('По алфавиту, без рекомендаций',
              style: StageText.body(12.5, color: StageColors.textMuted)),
          const SizedBox(height: 12),
          for (final p in all) ...[
            _Choice(
              title: p.name,
              subtitle: p.isCustom
                  ? 'Адрес API, модель и ключ — свои'
                  : p.verifiedLive
                      ? ''
                      : 'не проверено вживую',
              selected: settings.provider?.id == p.id,
              onTap: () => settings.selectProvider(p.id),
              badge: settings.hasKeyFor(p.id) ? 'ключ есть' : null,
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _ProviderDetails extends StatefulWidget {
  const _ProviderDetails({
    super.key,
    required this.provider,
    required this.settings,
  });

  final ProviderInfo provider;
  final SettingsStore settings;

  @override
  State<_ProviderDetails> createState() => _ProviderDetailsState();
}

class _ProviderDetailsState extends State<_ProviderDetails> {
  late final _model =
      TextEditingController(text: widget.settings.modelFor(widget.provider.id));
  late final _url =
      TextEditingController(text: widget.settings.customBaseUrl);
  late final _maxFrames = TextEditingController(
      text: widget.settings.maxFramesFor(widget.provider.id)?.toString() ?? '');
  final _key = TextEditingController();
  bool _keyLoaded = false;
  bool _showKey = false;
  Timer? _saveKeyTimer;

  /// Подсказка о возможностях модели (spec 7.2): null — ничего не знаем.
  ModelLookup? _lookup;
  Timer? _lookupTimer;
  CancelToken? _lookupCancel;

  @override
  void initState() {
    super.initState();
    // Ключ читается из защищённого хранилища только на время этого экрана.
    widget.settings.readKey(widget.provider.id).then((k) {
      if (!mounted) return;
      setState(() {
        _key.text = k ?? '';
        _keyLoaded = true;
      });
      _scheduleLookup();
    });
  }

  /// Узнаём, что принимает модель, через секунду после последней правки.
  /// Нет сети или API не умеет — молча ничего не показываем.
  void _scheduleLookup() {
    _lookupTimer?.cancel();
    _lookupCancel?.cancel();
    if (_lookup != null) setState(() => _lookup = null);
    _lookupTimer = Timer(const Duration(milliseconds: 900), _runLookup);
  }

  Future<void> _runLookup() async {
    final p = widget.provider;
    final s = widget.settings;
    final model = _model.text.trim();
    final key = _key.text.trim();
    final url = s.baseUrlFor(p).trim();
    if (!mounted || model.isEmpty || key.isEmpty || url.isEmpty) return;
    final cancel = _lookupCancel = CancelToken();
    final provider = AdapterRegistry.create(
      provider: p,
      model: model,
      apiKey: key,
      baseUrl: url,
      transport: AppScope.of(context).transport,
    );
    ModelLookup? r;
    try {
      r = await provider.lookupModel(cancel);
    } catch (_) {
      r = null;
    }
    if (!mounted || cancel.isCancelled) return;
    setState(() => _lookup = r);
  }

  @override
  void dispose() {
    _lookupTimer?.cancel();
    _lookupCancel?.cancel();
    if (_saveKeyTimer?.isActive ?? false) {
      _saveKeyTimer!.cancel();
      widget.settings.saveKey(widget.provider.id, _key.text);
    }
    _model.dispose();
    _url.dispose();
    _maxFrames.dispose();
    _key.dispose();
    super.dispose();
  }

  void _onKeyChanged(String value) {
    _saveKeyTimer?.cancel();
    _saveKeyTimer = Timer(const Duration(milliseconds: 500),
        () => widget.settings.saveKey(widget.provider.id, value));
    _scheduleLookup();
  }

  Widget? _lookupHint(ProviderInfo p, SettingsStore s, bool canVideo) {
    final l = _lookup;
    if (l == null) return null;
    final muted = StageText.body(12.5, color: StageColors.textMuted);
    if (!l.found) {
      return Text('Модель не найдена у провайдера — проверьте название.',
          style: StageText.body(12.5, color: StageColors.partial));
    }
    final mods = l.inputModalities;
    if (mods == null) return Text('Модель найдена.', style: muted);
    const names = {'image': 'изображения', 'video': 'видео', 'audio': 'звук'};
    final shown = [for (final m in names.keys) if (mods.contains(m)) names[m]!];
    final takesVideo = mods.contains('video');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          shown.isEmpty
              ? 'Модель не принимает изображения — для анализа танца нужна '
                  'другая модель.'
              : 'Модель принимает: ${shown.join(', ')}.'
                  '${takesVideo && !mods.contains('audio') ? ' Звук в видео '
                      'модель может не слышать — о музыке судит по анализу '
                      'музыки.' : ''}',
          style: shown.isEmpty
              ? StageText.body(12.5, color: StageColors.partial)
              : muted,
        ),
        if (takesVideo && canVideo && !s.videoModeFor(p))
          TextButton(
            onPressed: () => s.setVideoMode(p.id, true),
            child: const Text('Включить «видео со звуком»'),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    final s = widget.settings;
    final canVideo = s.canSendVideo(p);

    return GlowCard(
      accent: DanceAccent.neutral,
      glow: 0.2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(p.name, style: StageText.display(22)),
          if (!p.verifiedLive) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Pill(
                  label: 'не проверено вживую', color: StageColors.partial),
            ),
          ],
          if (p.freeNoteRu != null) ...[
            const SizedBox(height: 6),
            Text(p.freeNoteRu!,
                style: StageText.body(13.5, color: StageColors.textSecondary)),
          ],
          if (p.hintRu != null) ...[
            const SizedBox(height: 6),
            Text(p.hintRu!,
                style: StageText.body(13.5, color: StageColors.textSecondary)),
          ],
          const SizedBox(height: 18),
          if (p.isCustom) ...[
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Адрес API',
                hintText: 'https://…/v1',
              ),
              onChanged: (v) {
                s.setCustomBaseUrl(v);
                _scheduleLookup();
              },
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _model,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Модель',
              hintText: 'Название модели у провайдера',
            ),
            onChanged: (v) {
              s.setModel(p.id, v.trim());
              _scheduleLookup();
            },
          ),
          if (_lookupHint(p, s, canVideo) case final hint?) ...[
            const SizedBox(height: 6),
            hint,
          ],
          if (p.modelHintRu != null) ...[
            const SizedBox(height: 6),
            Text(p.modelHintRu!,
                style: StageText.body(12.5, color: StageColors.textMuted)),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _maxFrames,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'Максимум кадров',
              hintText: 'По умолчанию — '
                  '${AdapterRegistry.capabilitiesFor(p.apiType).frameOptions.maxFrames}',
              helperText: 'Если модель отклоняет запрос с большим числом '
                  'изображений. Пусто — по умолчанию.',
              helperMaxLines: 2,
              helperStyle: StageText.body(12, color: StageColors.textMuted),
            ),
            onChanged: (v) => s.setMaxFrames(p.id, int.tryParse(v)),
          ),
          if (p.recommendedModels.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final m in p.recommendedModels)
                  ActionChip(
                    label: Text(m),
                    onPressed: () {
                      _model.text = m;
                      s.setModel(p.id, m);
                      _scheduleLookup();
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            enabled: _keyLoaded,
            obscureText: !_showKey,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            decoration: InputDecoration(
              labelText: 'Ключ API',
              hintText: _keyLoaded ? 'Вставьте ключ' : 'Загрузка…',
              helperText: 'Хранится только на этом устройстве, '
                  'в защищённом хранилище',
              helperStyle: StageText.body(12, color: StageColors.textMuted),
              suffixIcon: IconButton(
                tooltip: _showKey ? 'Скрыть ключ' : 'Показать ключ',
                icon: Icon(_showKey
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined),
                onPressed: () => setState(() => _showKey = !_showKey),
              ),
            ),
            onChanged: _onKeyChanged,
          ),
          const SizedBox(height: 16),
          Opacity(
            opacity: canVideo ? 1 : 0.5,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Модель принимает видео со звуком',
                  style: StageText.body(15, weight: 600)),
              subtitle: Text(
                canVideo
                    ? 'Включите, если модель понимает видео: оно уйдёт целиком. '
                        'Иначе — кадры и анализ музыки.'
                    : 'Этот тип API не умеет передавать видео — '
                        'используются кадры и анализ музыки.',
                style: StageText.body(12.5, color: StageColors.textMuted),
              ),
              value: s.videoModeFor(p),
              onChanged: canVideo ? (v) => s.setVideoMode(p.id, v) : null,
            ),
          ),
          if (p.fallbackModels.isNotEmpty)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Использовать запасные модели при перегрузке',
                  style: StageText.body(15, weight: 600)),
              subtitle: Text(
                'Если модель перегружена или исчерпала лимит, анализ '
                'продолжит другая модель: '
                '${p.fallbackModels.map((f) => f.id).join(', ')}.',
                style: StageText.body(12.5, color: StageColors.textMuted),
              ),
              value: s.useFallbackFor(p.id),
              onChanged: (v) => s.setUseFallback(p.id, v),
            ),
          if (!p.isCustom) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: GhostButton(
                label: 'Как получить ключ',
                icon: Icons.help_outline_rounded,
                onPressed: () => Navigator.of(context)
                    .push(stageRoute(KeyHelpScreen(provider: p))),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
