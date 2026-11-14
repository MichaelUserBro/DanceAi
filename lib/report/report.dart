// Модель отчёта ИИ по assets/report.schema.json.
// Строится только из JSON, уже прошедшего ReportValidator.

/// Значения enum'ов как в JSON.
abstract interface class WireEnum {
  String get wire;
}

T _parse<T extends WireEnum>(List<T> values, Object? raw) =>
    values.firstWhere((v) => v.wire == raw,
        orElse: () => throw FormatException('Недопустимое значение: $raw'));

T? _parseNullable<T extends WireEnum>(List<T> values, Object? raw) =>
    raw == null ? null : _parse(values, raw);

enum Verdict implements WireEnum {
  good('good'),
  partial('partial'),
  poor('poor'),
  notVisible('not_visible');

  const Verdict(this.wire);
  @override
  final String wire;
}

enum VideoStatus implements WireEnum {
  ok('ok'),
  lowConfidence('low_confidence'),
  unusable('unusable');

  const VideoStatus(this.wire);
  @override
  final String wire;
}

enum VideoQuality implements WireEnum {
  good('good'),
  acceptable('acceptable'),
  poor('poor');

  const VideoQuality(this.wire);
  @override
  final String wire;
}

enum MusicSource implements WireEnum {
  audio('audio'),
  analysis('analysis'),
  audioAndAnalysis('audio_and_analysis'),
  none('none');

  const MusicSource(this.wire);
  @override
  final String wire;
}

enum Confidence implements WireEnum {
  high('high'),
  medium('medium'),
  low('low');

  const Confidence(this.wire);
  @override
  final String wire;
}

enum Severity implements WireEnum {
  critical('critical'),
  major('major'),
  minor('minor');

  const Severity(this.wire);
  @override
  final String wire;
}

enum Who implements WireEnum {
  leader('leader'),
  follower('follower'),
  couple('couple');

  const Who(this.wire);
  @override
  final String wire;
}

List<String> _strings(Object? raw) => (raw as List).cast<String>();

class VideoAssessment {
  const VideoAssessment({
    required this.status,
    required this.quality,
    required this.coupleDescription,
    required this.musicSource,
    required this.issues,
  });

  factory VideoAssessment.fromJson(Map<String, dynamic> j) => VideoAssessment(
        status: _parse(VideoStatus.values, j['status']),
        quality: _parse(VideoQuality.values, j['quality']),
        coupleDescription: j['couple_description'] as String,
        musicSource: _parse(MusicSource.values, j['music_source']),
        issues: _strings(j['issues']),
      );

  final VideoStatus status;
  final VideoQuality quality;
  final String coupleDescription;
  final MusicSource musicSource;
  final List<String> issues;
}

class ReportFigure {
  const ReportFigure({
    required this.figureId,
    required this.nameRu,
    required this.nameEn,
    required this.count,
    required this.quality,
    required this.confidence,
    required this.comment,
  });

  factory ReportFigure.fromJson(Map<String, dynamic> j) => ReportFigure(
        figureId: j['figure_id'] as String?,
        nameRu: j['name_ru'] as String,
        nameEn: j['name_en'] as String?,
        count: j['count'] as int,
        quality: _parse(Verdict.values, j['quality']),
        confidence: _parse(Confidence.values, j['confidence']),
        comment: j['comment'] as String,
      );

  final String? figureId;
  final String nameRu;
  final String? nameEn;
  final int count;
  final Verdict quality;
  final Confidence confidence;
  final String comment;
}

class CriterionResult {
  const CriterionResult({
    required this.criterionId,
    required this.couple,
    required this.leader,
    required this.follower,
    required this.comment,
  });

  factory CriterionResult.fromJson(Map<String, dynamic> j) => CriterionResult(
        criterionId: j['criterion_id'] as String,
        couple: _parse(Verdict.values, j['couple']),
        leader: _parseNullable(Verdict.values, j['leader']),
        follower: _parseNullable(Verdict.values, j['follower']),
        comment: j['comment'] as String,
      );

  final String criterionId;
  final Verdict couple;
  final Verdict? leader;
  final Verdict? follower;
  final String comment;
}

/// Ошибка в танце (поле `errors` отчёта).
class Mistake {
  const Mistake({
    required this.severity,
    required this.who,
    required this.componentId,
    required this.criterionId,
    required this.figureId,
    required this.description,
  });

  factory Mistake.fromJson(Map<String, dynamic> j) => Mistake(
        severity: _parse(Severity.values, j['severity']),
        who: _parse(Who.values, j['who']),
        componentId: j['component'] as String,
        criterionId: j['criterion_id'] as String?,
        figureId: j['figure_id'] as String?,
        description: j['description'] as String,
      );

  final Severity severity;
  final Who who;
  final String componentId;
  final String? criterionId;
  final String? figureId;
  final String description;
}

class PersonSummary {
  const PersonSummary({required this.strengths, required this.weaknesses});

  factory PersonSummary.fromJson(Map<String, dynamic> j) => PersonSummary(
        strengths: _strings(j['strengths']),
        weaknesses: _strings(j['weaknesses']),
      );

  final List<String> strengths;
  final List<String> weaknesses;
}

class ReportSummary {
  const ReportSummary({
    required this.overallComment,
    required this.leader,
    required this.follower,
    required this.couple,
  });

  factory ReportSummary.fromJson(Map<String, dynamic> j) => ReportSummary(
        overallComment: j['overall_comment'] as String,
        leader: PersonSummary.fromJson(j['leader'] as Map<String, dynamic>),
        follower: PersonSummary.fromJson(j['follower'] as Map<String, dynamic>),
        couple: PersonSummary.fromJson(j['couple'] as Map<String, dynamic>),
      );

  final String overallComment;
  final PersonSummary leader;
  final PersonSummary follower;
  final PersonSummary couple;

  PersonSummary of(Who who) => switch (who) {
        Who.leader => leader,
        Who.follower => follower,
        Who.couple => couple,
      };
}

class ComponentScore {
  const ComponentScore({
    required this.couple,
    required this.leader,
    required this.follower,
    required this.comment,
  });

  factory ComponentScore.fromJson(Map<String, dynamic> j) => ComponentScore(
        couple: j['couple'] as int,
        leader: j['leader'] as int?,
        follower: j['follower'] as int?,
        comment: j['comment'] as String,
      );

  final int couple;
  final int? leader;
  final int? follower;
  final String comment;

  int? of(Who who) => switch (who) {
        Who.leader => leader,
        Who.follower => follower,
        Who.couple => couple,
      };
}

class DanceReport {
  const DanceReport({
    required this.schemaVersion,
    required this.danceId,
    required this.videoAssessment,
    required this.figures,
    required this.criteriaResults,
    required this.mistakes,
    required this.summary,
    required this.scores,
    required this.priorities,
    required this.additionalObservations,
  });

  factory DanceReport.fromJson(Map<String, dynamic> j) {
    final scores = j['scores'] as Map<String, dynamic>;
    return DanceReport(
      schemaVersion: j['schema_version'] as String,
      danceId: j['dance_id'] as String,
      videoAssessment: VideoAssessment.fromJson(
          j['video_assessment'] as Map<String, dynamic>),
      figures: [
        for (final f in j['figures'] as List)
          ReportFigure.fromJson(f as Map<String, dynamic>),
      ],
      criteriaResults: [
        for (final c in j['criteria_results'] as List)
          CriterionResult.fromJson(c as Map<String, dynamic>),
      ],
      mistakes: [
        for (final e in j['errors'] as List)
          Mistake.fromJson(e as Map<String, dynamic>),
      ],
      summary: ReportSummary.fromJson(j['summary'] as Map<String, dynamic>),
      scores: {
        for (final e in scores.entries)
          e.key: ComponentScore.fromJson(e.value as Map<String, dynamic>),
      },
      priorities: _strings(j['priorities']),
      additionalObservations: _strings(j['additional_observations']),
    );
  }

  final String schemaVersion;
  final String danceId;
  final VideoAssessment videoAssessment;
  final List<ReportFigure> figures;
  final List<CriterionResult> criteriaResults;

  /// Поле `errors` отчёта: от самых важных к менее важным.
  final List<Mistake> mistakes;
  final ReportSummary summary;

  /// id компонента → оценка.
  final Map<String, ComponentScore> scores;
  final List<String> priorities;
  final List<String> additionalObservations;

  /// Для краткого отчёта (spec 6): до 3 первых грубых ошибок,
  /// если грубых нет — первые 3 ошибки.
  List<Mistake> get keyMistakes {
    final critical =
        mistakes.where((m) => m.severity == Severity.critical).take(3).toList();
    return critical.isNotEmpty ? critical : mistakes.take(3).toList();
  }

  /// Есть ли у кого-то из пары хотя бы одна отдельная оценка.
  bool hasPersonScores(Who who) =>
      scores.values.any((s) => s.of(who) != null);
}
