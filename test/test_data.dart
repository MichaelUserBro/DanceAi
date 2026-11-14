import 'dart:convert';
import 'dart:io';

import 'package:dance_ai/data/app_data.dart';

/// AppData из файлов репозитория (тесты запускаются из корня проекта).
AppData loadTestAppData() {
  String read(String path) => File(path).readAsStringSync();
  final p = AppData.assetPaths;
  return AppData.fromStrings(
    criteriaJson: read(p.criteria),
    providersJson: read(p.providers),
    reportSchemaJson: read(p.reportSchema),
    systemPrompt: read(p.system),
    userPrompt: read(p.user),
    inputVideo: read(p.inputVideo),
    inputFrames: read(p.inputFrames),
  );
}

/// Новая изменяемая копия примера отчёта.
Map<String, dynamic> loadExampleReportJson() =>
    jsonDecode(File('test/fixtures/report_example.json').readAsStringSync())
        as Map<String, dynamic>;
