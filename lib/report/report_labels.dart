import 'report.dart';

// Русские подписи значений отчёта (spec 6).

extension VerdictLabel on Verdict {
  String get labelRu => switch (this) {
        Verdict.good => 'выполняется',
        Verdict.partial => 'частично',
        Verdict.poor => 'не выполняется',
        Verdict.notVisible => 'не видно',
      };
}

extension SeverityLabel on Severity {
  String get labelRu => switch (this) {
        Severity.critical => 'грубая',
        Severity.major => 'заметная',
        Severity.minor => 'мелкая',
      };
}

extension WhoLabel on Who {
  String get labelRu => switch (this) {
        Who.leader => 'партнёр',
        Who.follower => 'партнёрша',
        Who.couple => 'пара',
      };

  String get titleRu => switch (this) {
        Who.leader => 'Партнёр',
        Who.follower => 'Партнёрша',
        Who.couple => 'Пара',
      };
}

extension ConfidenceLabel on Confidence {
  String get labelRu => switch (this) {
        Confidence.high => 'уверенно',
        Confidence.medium => 'вероятно',
        Confidence.low => 'не уверен',
      };
}

extension VideoStatusLabel on VideoStatus {
  String get labelRu => switch (this) {
        VideoStatus.ok => 'Видео подходит',
        VideoStatus.lowConfidence => 'Оценка неточная',
        VideoStatus.unusable => 'Оценить по существу нельзя',
      };
}

extension VideoQualityLabel on VideoQuality {
  String get labelRu => switch (this) {
        VideoQuality.good => 'хорошо',
        VideoQuality.acceptable => 'приемлемо',
        VideoQuality.poor => 'плохо',
      };
}

extension MusicSourceLabel on MusicSource {
  String get labelRu => switch (this) {
        MusicSource.audio => 'по звуку видео',
        MusicSource.analysis => 'по анализу музыки',
        MusicSource.audioAndAnalysis => 'по звуку и анализу музыки',
        MusicSource.none => 'без музыки',
      };
}
