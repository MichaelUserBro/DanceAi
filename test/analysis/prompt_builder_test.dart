import 'package:dance_ai/analysis/prompt_builder.dart';
import 'package:dance_ai/analysis/video_preparer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_data.dart';

void main() {
  final data = loadTestAppData();
  final builder = PromptBuilder(data);

  PreparedMaterial material({double? duration = 93.4, int frames = 3}) =>
      PreparedMaterial(
        videoPath: 'video.mp4',
        durationSec: duration,
        frames: [
          for (var i = 0; i < frames; i++)
            VideoFrame(timeSec: i * 0.5, path: 'f$i.jpg'),
        ],
        fps: 2,
        musicAnalysis: musicAnalysisUnavailable,
      );

  for (final dance in data.criteria.dances) {
    for (final mode in SubmissionMode.values) {
      test('${dance.id} / ${mode.name}: в промпте не остаётся {{', () {
        final p = builder.build(dance: dance, mode: mode, material: material());
        expect(p.system, isNot(contains('{{')));
        expect(p.user, isNot(contains('{{')));
        expect(p.user, contains('dance_id: `${dance.id}`'));
        expect(p.user, contains(dance.nameRu));
        expect(p.user, contains(musicAnalysisUnavailable));
        expect(p.user, contains('"criteria_results"'));
        for (final c in data.criteria.criteriaFor(dance)) {
          expect(p.user, contains('${c.id} — ${c.nameRu} [компонент: '));
        }
        for (final f in dance.figures) {
          expect(p.user, contains('${f.id} — ${f.nameRu}'));
        }
        if (mode == SubmissionMode.frames) {
          expect(p.user, contains('Число кадров: 3'));
          expect(p.user, contains('Частота: около 2 кадр/с'));
        } else {
          expect(p.user, contains('Передано видео со звуком'));
        }
        expect(p.user, contains('93.4'));
      });
    }
  }

  test('формат строк критериев и фигур', () {
    final waltz = data.criteria.dance('slow_waltz');
    expect(builder.criteriaBlock(waltz),
        contains('figure_execution — Правильное исполнение фигур '
            '[компонент: choreography_presentation; '
            'отдельно партнёр и партнёрша: нет]'));
    expect(builder.figuresBlock(waltz),
        contains('whisk — Виск (Whisk)\n'));
    expect(builder.figuresBlock(waltz),
        contains('levyi_valsovyi_povorot — Левый вальсовый поворот — Отдельная'));
    expect(builder.componentsBlock(), startsWith('technique — Техника: '));
  });

  test('неизвестная длительность', () {
    final p = builder.build(
        dance: data.criteria.dances.first,
        mode: SubmissionMode.video,
        material: material(duration: null));
    expect(p.user, contains('неизвестно'));
  });

  test('незаполненный плейсхолдер — ошибка', () {
    expect(() => PromptBuilder.fill('{{a}} {{b}}', {'a': '1'}),
        throwsStateError);
  });

  test('повторный запрос перечисляет ошибки', () {
    final note = builder.retryNote(['ошибка 1', 'ошибка 2']);
    expect(note, contains('- ошибка 1'));
    expect(note, contains('- ошибка 2'));
  });

  test('formatNumber', () {
    expect(PromptBuilder.formatNumber(2, decimals: 2), '2');
    expect(PromptBuilder.formatNumber(2.5, decimals: 2), '2.5');
    expect(PromptBuilder.formatNumber(93.44, decimals: 1), '93.4');
  });
}
