// Типизированная модель assets/criteria.json. Критерии в коде не хардкодятся.

enum DanceStyle {
  standard('standard', 'Стандарт'),
  latin('latin', 'Латина');

  const DanceStyle(this.wire, this.labelRu);
  final String wire;
  final String labelRu;

  static DanceStyle fromWire(String value) =>
      values.firstWhere((s) => s.wire == value,
          orElse: () => throw FormatException('Неизвестный стиль: $value'));
}

class ScoreComponent {
  const ScoreComponent({
    required this.id,
    required this.nameRu,
    required this.descriptionRu,
  });

  factory ScoreComponent.fromJson(Map<String, dynamic> json) => ScoreComponent(
        id: json['id'] as String,
        nameRu: json['name_ru'] as String,
        descriptionRu: json['description_ru'] as String,
      );

  final String id;
  final String nameRu;
  final String descriptionRu;
}

class Criterion {
  const Criterion({
    required this.id,
    required this.nameRu,
    required this.componentId,
    required this.perPerson,
  });

  factory Criterion.fromJson(Map<String, dynamic> json) => Criterion(
        id: json['id'] as String,
        nameRu: json['name_ru'] as String,
        componentId: json['component'] as String,
        perPerson: json['per_person'] as bool,
      );

  final String id;
  final String nameRu;
  final String componentId;
  final bool perPerson;
}

class Figure {
  const Figure({
    required this.id,
    required this.nameRu,
    this.nameEn,
    this.noteRu,
  });

  factory Figure.fromJson(Map<String, dynamic> json) => Figure(
        id: json['id'] as String,
        nameRu: json['name_ru'] as String,
        nameEn: json['name_en'] as String?,
        noteRu: json['note_ru'] as String?,
      );

  final String id;
  final String nameRu;
  final String? nameEn;
  final String? noteRu;
}

/// Размер и турнирный темп (такты в минуту) — подсказка для анализа музыки.
class DanceMusic {
  const DanceMusic({
    required this.meter,
    required this.tempoMinMpm,
    required this.tempoMaxMpm,
  });

  factory DanceMusic.fromJson(Map<String, dynamic> json) {
    final tempo = (json['tempo_mpm'] as List).cast<num>();
    return DanceMusic(
      meter: json['meter'] as String,
      tempoMinMpm: tempo[0].toInt(),
      tempoMaxMpm: tempo[1].toInt(),
    );
  }

  final String meter;
  final int tempoMinMpm;
  final int tempoMaxMpm;

  /// Число долей в такте (числитель размера).
  int get beatsPerBar => int.parse(meter.split('/').first);
}

class Dance {
  const Dance({
    required this.id,
    required this.nameRu,
    required this.nameEn,
    required this.style,
    required this.music,
    required this.criteria,
    required this.figures,
  });

  factory Dance.fromJson(Map<String, dynamic> json) => Dance(
        id: json['id'] as String,
        nameRu: json['name_ru'] as String,
        nameEn: json['name_en'] as String,
        style: DanceStyle.fromWire(json['style'] as String),
        music: DanceMusic.fromJson(json['music'] as Map<String, dynamic>),
        criteria: [
          for (final c in json['criteria'] as List)
            Criterion.fromJson(c as Map<String, dynamic>),
        ],
        figures: [
          for (final f in json['figures'] as List)
            Figure.fromJson(f as Map<String, dynamic>),
        ],
      );

  final String id;
  final String nameRu;
  final String nameEn;
  final DanceStyle style;
  final DanceMusic music;

  /// Только критерии танца, без общих.
  final List<Criterion> criteria;
  final List<Figure> figures;

  Figure? figureById(String? id) {
    if (id == null) return null;
    for (final f in figures) {
      if (f.id == id) return f;
    }
    return null;
  }
}

class CriteriaCatalog {
  const CriteriaCatalog({
    required this.version,
    required this.scaleMin,
    required this.scaleMax,
    required this.components,
    required this.generalCriteria,
    required this.dances,
  });

  factory CriteriaCatalog.fromJson(Map<String, dynamic> json) {
    final scale = json['scale'] as Map<String, dynamic>;
    return CriteriaCatalog(
      version: json['version'] as String,
      scaleMin: scale['min'] as int,
      scaleMax: scale['max'] as int,
      components: [
        for (final c in json['components'] as List)
          ScoreComponent.fromJson(c as Map<String, dynamic>),
      ],
      generalCriteria: [
        for (final c in json['general_criteria'] as List)
          Criterion.fromJson(c as Map<String, dynamic>),
      ],
      dances: [
        for (final d in json['dances'] as List)
          Dance.fromJson(d as Map<String, dynamic>),
      ],
    );
  }

  final String version;
  final int scaleMin;
  final int scaleMax;
  final List<ScoreComponent> components;
  final List<Criterion> generalCriteria;
  final List<Dance> dances;

  Dance dance(String id) => dances.firstWhere((d) => d.id == id,
      orElse: () => throw ArgumentError.value(id, 'id', 'Неизвестный танец'));

  ScoreComponent component(String id) => components.firstWhere((c) => c.id == id,
      orElse: () => throw ArgumentError.value(id, 'id', 'Неизвестный компонент'));

  /// Общие критерии + критерии танца — полный обязательный список.
  List<Criterion> criteriaFor(Dance dance) =>
      [...generalCriteria, ...dance.criteria];

  Criterion? criterion(Dance dance, String? id) {
    if (id == null) return null;
    for (final c in criteriaFor(dance)) {
      if (c.id == id) return c;
    }
    return null;
  }
}
