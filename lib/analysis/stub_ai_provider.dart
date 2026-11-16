import 'dart:convert';
import 'dart:math';

import '../data/criteria.dart';
import 'ai_provider.dart';
import 'cancel_token.dart';
import 'video_preparer.dart';

/// Сценарии заглушки для проверки экранов и ошибок (spec 7.8).
enum StubScenario {
  normal('normal', 'Нормальный ответ'),
  lowConfidence('low_confidence', 'low_confidence — оценка неточная'),
  unusable('unusable', 'unusable — оценить нельзя'),
  partialScores('partial_scores', 'Нет части личных оценок'),
  invalidJson('invalid_json', 'Невалидный JSON'),
  invalidKey('invalid_key', 'Неверный ключ'),
  rateLimit('rate_limit', 'Лимит запросов'),
  network('network', 'Нет сети');

  const StubScenario(this.id, this.labelRu);
  final String id;
  final String labelRu;

  static StubScenario fromId(String? id) =>
      values.firstWhere((s) => s.id == id, orElse: () => normal);
}

/// Заглушка ИИ: тот же интерфейс, что у адаптеров. Ждёт 3–5 с и возвращает
/// текст JSON-отчёта, собранный по criteria.json. Ответ проходит ту же
/// обработку, что и настоящий.
class StubAiProvider implements AiProvider {
  StubAiProvider({
    required this.catalog,
    required this.scenario,
    this.minDelay = const Duration(seconds: 3),
    this.maxDelay = const Duration(seconds: 5),
    int? seed,
  }) : _random = Random(seed);

  final CriteriaCatalog catalog;
  final StubScenario scenario;
  final Duration minDelay;
  final Duration maxDelay;
  final Random _random;

  @override
  String get displayName => 'Демо-режим';

  @override
  AiCapabilities get capabilities => const AiCapabilities(supportsVideo: true);

  @override
  Future<String> analyze(
    AiRequest request, {
    required void Function(AiPhase) onPhase,
    required CancelToken cancel,
  }) async {
    final spanMs = maxDelay.inMilliseconds - minDelay.inMilliseconds;
    final total = minDelay.inMilliseconds +
        (spanMs > 0 ? _random.nextInt(spanMs + 1) : 0);
    final sendMs = (total * 0.2).round();

    onPhase(AiPhase.sending);
    await cancel.delay(Duration(milliseconds: sendMs));
    switch (scenario) {
      case StubScenario.network:
        throw const AiException(AiErrorKind.network, 'Заглушка: нет сети');
      case StubScenario.invalidKey:
        throw const AiException(AiErrorKind.invalidKey, 'Заглушка: HTTP 401');
      default:
    }
    onPhase(AiPhase.waiting);
    await cancel.delay(Duration(milliseconds: total - sendMs));

    switch (scenario) {
      case StubScenario.rateLimit:
        throw const AiException(AiErrorKind.rateLimit, 'Заглушка: HTTP 429');
      case StubScenario.invalidJson:
        return 'Конечно! Вот оценка танца: {"schema_version": "1.0", "dance_id": ';
      default:
    }
    final report = generateReport(
      catalog.dance(request.danceId),
      status: switch (scenario) {
        StubScenario.lowConfidence => 'low_confidence',
        StubScenario.unusable => 'unusable',
        _ => 'ok',
      },
      mode: request.mode,
      partialScores: scenario == StubScenario.partialScores,
    );
    // Как настоящие модели, иногда оборачивает JSON в ```json.
    final text = const JsonEncoder.withIndent('  ').convert(report);
    return _random.nextBool() ? '```json\n$text\n```' : text;
  }

  /// Валидный отчёт для любого танца по criteria.json.
  Map<String, dynamic> generateReport(
    Dance dance, {
    required String status,
    SubmissionMode mode = SubmissionMode.frames,
    bool partialScores = false,
  }) {
    final r = _random;
    final unusable = status == 'unusable';
    T pick<T>(List<T> items) => items[r.nextInt(items.length)];

    // Оценки пары: 3–6 (типично для Хобби), при unusable — 1–3.
    int score() => unusable ? 1 + r.nextInt(3) : 3 + r.nextInt(4);
    int around(int v) => (v + r.nextInt(3) - 1).clamp(1, 10);

    String verdict() {
      if (unusable) return pick(['not_visible', 'not_visible', 'poor']);
      final x = r.nextDouble();
      if (x < 0.22) return 'good';
      if (x < 0.62) return 'partial';
      if (x < 0.93) return 'poor';
      return 'not_visible';
    }

    // Фигуры: 3–5 из списка + одна не из списка.
    final figurePool = [...dance.figures]..shuffle(r);
    final shown = figurePool.take(min(figurePool.length, 3 + r.nextInt(3)));
    final figures = <Map<String, dynamic>>[
      for (final f in shown)
        {
          'figure_id': f.id,
          'name_ru': f.nameRu,
          'name_en': f.nameEn,
          'count': 1 + r.nextInt(4),
          'quality': pick(['good', 'partial', 'partial', 'poor']),
          'confidence': pick(['high', 'high', 'medium', 'low']),
          'comment': 'Демо: ${pick(_figureNotes)}',
        },
      {
        'figure_id': null,
        'name_ru': 'Связка не из списка',
        'name_en': null,
        'count': 1,
        'quality': 'partial',
        'confidence': 'low',
        'comment': 'Демо: фигура не из списка — figure_id = null.',
      },
    ];

    final criteria = catalog.criteriaFor(dance);
    final criteriaResults = [
      for (final c in criteria)
        {
          'criterion_id': c.id,
          'couple': verdict(),
          'leader': c.perPerson ? verdict() : null,
          'follower': c.perPerson ? verdict() : null,
          'comment': 'Демо: вердикт заглушки по критерию «${c.nameRu}».',
        },
    ];

    // Ошибки: 10–15, от грубых к мелким.
    final errorCount = unusable ? 3 : 10 + r.nextInt(6);
    final shownFigureIds = [for (final f in shown) f.id];
    final errors = <Map<String, dynamic>>[];
    for (var i = 0; i < errorCount; i++) {
      final c = pick(criteria);
      final severity = i < 2
          ? 'critical'
          : (i < errorCount * 0.55 ? 'major' : 'minor');
      final who = c.perPerson ? pick(['leader', 'follower', 'couple']) : 'couple';
      final withFigure = shownFigureIds.isNotEmpty && r.nextBool();
      final minute = r.nextInt(2);
      final second = r.nextInt(60).toString().padLeft(2, '0');
      errors.add({
        'severity': severity,
        'who': who,
        'component': c.componentId,
        'criterion_id': c.id,
        'figure_id': withFigure ? pick(shownFigureIds) : null,
        'description':
            'Демо: «${c.nameRu}» — ${pick(_mistakeNotes)} ($minute:$second).',
      });
    }

    // Личные оценки: обычно у обоих все; редко (1 из 10) — один пропуск.
    // Сценарий «Нет части личных оценок»: у партнёрши нет 1–2 компонентов,
    // у партнёра — другого.
    final compIds = [for (final c in catalog.components) c.id]..shuffle(r);
    final noLeader = <String>{};
    final noFollower = <String>{};
    if (partialScores) {
      noFollower.addAll(compIds.take(1 + r.nextInt(2)));
      noLeader.add(compIds.last);
    } else if (r.nextInt(10) == 0) {
      (r.nextBool() ? noLeader : noFollower).add(compIds.first);
    }
    final scores = <String, dynamic>{};
    for (final comp in catalog.components) {
      final couple = score();
      scores[comp.id] = {
        'couple': couple,
        'leader': noLeader.contains(comp.id) ? null : around(couple),
        'follower': noFollower.contains(comp.id) ? null : around(couple),
        'comment': 'Демо: оценка заглушки за «${comp.nameRu}».',
      };
    }

    final issues = switch (status) {
      'low_confidence' => [
          'Демо: пара большую часть времени далеко от камеры.',
          'Демо: ноги часто закрыты другими парами.',
        ],
      'unusable' => [
          'Демо: пара почти не видна — съёмка издалека в тёмном зале.',
          'Демо: неясно, какую пару оценивать.',
        ],
      _ => <String>[],
    };

    List<String> few(List<String> pool, int n) =>
        ([...pool]..shuffle(r)).take(n).toList();

    return {
      'schema_version': '1.0',
      'dance_id': dance.id,
      'video_assessment': {
        'status': status,
        'quality': switch (status) {
          'ok' => 'good',
          'low_confidence' => 'acceptable',
          _ => 'poor',
        },
        'couple_description':
            'Демо: пара в центре кадра, партнёр в чёрном, партнёрша в ярком платье.',
        'music_source':
            mode == SubmissionMode.video ? 'audio_and_analysis' : 'analysis',
        'issues': issues,
      },
      'figures': unusable ? <Map<String, dynamic>>[] : figures,
      'criteria_results': criteriaResults,
      'errors': errors,
      'summary': {
        'overall_comment': unusable
            ? 'Демо: оценить танец по существу нельзя — пара почти не видна.'
            : 'Демо-отчёт заглушки: ИИ не подключён. Схема фигур выучена, '
                'основные проблемы — в технике и работе в паре. '
                'Оценки и тексты сгенерированы случайно по criteria.json.',
        'leader': {
          'strengths': few(_strengths, 2),
          'weaknesses': few(_weaknesses, 2),
        },
        'follower': {
          'strengths': few(_strengths, 1 + r.nextInt(2)),
          'weaknesses': few(_weaknesses, 2),
        },
        'couple': {
          'strengths': few(_strengths, 2),
          'weaknesses': few(_weaknesses, 3),
        },
      },
      'scores': scores,
      'priorities': unusable
          ? [
              'Снимайте ближе: пара должна занимать заметную часть кадра.',
              'Снимайте при хорошем свете, чтобы были видны ноги.',
            ]
          : [
              for (final e in errors.take(3))
                'Демо: «${catalog.criterion(dance, e['criterion_id'] as String)!.nameRu}».',
            ],
      'additional_observations': [
        'Демо: это пример наблюдения за пределами списка критериев.',
      ],
    };
  }

  static const _figureNotes = [
    'фигура узнаваема, но недокручен поворот.',
    'исполнение уверенное, баланс сохраняется.',
    'потеря баланса в конце фигуры.',
    'рамка разъезжается на выходе из фигуры.',
  ];

  static const _mistakeNotes = [
    'нарушается в начале фигуры',
    'теряется к середине композиции',
    'выполняется непостоянно',
    'видно на смене направления',
    'заметно на сильной доле',
  ];

  static const _strengths = [
    'Демо: уверенно держит схему фигур.',
    'Демо: стабильный баланс.',
    'Демо: попадает в сильную долю.',
    'Демо: ровная линия корпуса.',
  ];

  static const _weaknesses = [
    'Демо: недоворот в поворотах.',
    'Демо: рамка оседает к середине.',
    'Демо: мало работы стопы.',
    'Демо: опережает музыку.',
    'Демо: напряжённые плечи.',
  ];
}
