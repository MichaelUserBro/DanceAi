import '../data/app_data.dart';
import '../data/criteria.dart';
import 'video_preparer.dart';

class BuiltPrompt {
  const BuiltPrompt({required this.system, required this.user});

  final String system;
  final String user;
}

/// Сборка промпта из шаблонов assets/prompts/ и данных (spec 7.5).
class PromptBuilder {
  const PromptBuilder(this.data);

  final AppData data;

  BuiltPrompt build({
    required Dance dance,
    required SubmissionMode mode,
    required PreparedMaterial material,
  }) {
    final t = data.templates;
    final duration = formatNumber(material.durationSec, decimals: 1);
    final inputDescription = switch (mode) {
      SubmissionMode.video => fill(t.inputVideo, {'duration_sec': duration}),
      SubmissionMode.frames => fill(t.inputFrames, {
          'duration_sec': duration,
          'frame_count': '${material.frames.length}',
          'fps': formatNumber(material.fps, decimals: 2),
        }),
    };

    final user = fill(t.user, {
      'dance_id': dance.id,
      'dance_name_ru': dance.nameRu,
      'dance_name_en': dance.nameEn,
      'input_description': inputDescription.trim(),
      'music_analysis': material.musicAnalysis.trim(),
      'components': componentsBlock(),
      'criteria': criteriaBlock(dance),
      'figures': figuresBlock(dance),
      'report_schema': data.reportSchemaText.trim(),
    });

    return BuiltPrompt(system: t.system.trim(), user: user.trim());
  }

  /// Дописывается к запросу при повторе (spec 7.7 п. 3).
  String retryNote(List<String> problems) {
    final shown = problems.take(30).toList();
    final more = problems.length - shown.length;
    return [
      '## Повторный запрос',
      'Предыдущий ответ не прошёл проверку. Исправь ошибки и верни заново '
          'полный JSON-объект по схеме, без текста до и после.',
      'Найденные ошибки:',
      for (final p in shown) '- $p',
      if (more > 0) '- … и ещё $more',
    ].join('\n');
  }

  /// Строка на компонент: `id — Название: описание`.
  String componentsBlock() => [
        for (final c in data.criteria.components)
          '${c.id} — ${c.nameRu}: ${c.descriptionRu}',
      ].join('\n');

  /// Строка на критерий: `id — Название [компонент: id; отдельно партнёр
  /// и партнёрша: да/нет]`.
  String criteriaBlock(Dance dance) => [
        for (final c in data.criteria.criteriaFor(dance))
          '${c.id} — ${c.nameRu} [компонент: ${c.componentId}; '
              'отдельно партнёр и партнёрша: ${c.perPerson ? 'да' : 'нет'}]',
      ].join('\n');

  /// Строка на фигуру: `id — Русское название (English name) — примечание`.
  String figuresBlock(Dance dance) => [
        for (final f in dance.figures)
          [
            '${f.id} — ${f.nameRu}',
            if (f.nameEn != null) ' (${f.nameEn})',
            if (f.noteRu != null) ' — ${f.noteRu}',
          ].join(),
      ].join('\n');

  /// Подстановка `{{key}}`. Оставшийся плейсхолдер — ошибка разработчика.
  static String fill(String template, Map<String, String> values) {
    final result = template.replaceAllMapped(
      RegExp(r'\{\{(\w+)\}\}'),
      (m) => values[m.group(1)] ?? m.group(0)!,
    );
    final left = RegExp(r'\{\{\w+\}\}').firstMatch(result);
    if (left != null) {
      throw StateError('Не подставлен плейсхолдер ${left.group(0)}');
    }
    return result;
  }

  /// 93.4 → «93.4», 2.0 → «2», null → «неизвестно».
  static String formatNumber(double? value, {required int decimals}) {
    if (value == null) return 'неизвестно';
    var s = value.toStringAsFixed(decimals);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }
}
