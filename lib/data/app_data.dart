import 'dart:convert';

import 'package:flutter/services.dart';

import 'criteria.dart';
import 'providers_catalog.dart';

/// Шаблоны промпта из assets/prompts/ и текст схемы отчёта.
class PromptTemplates {
  const PromptTemplates({
    required this.system,
    required this.user,
    required this.inputVideo,
    required this.inputFrames,
  });

  final String system;
  final String user;
  final String inputVideo;
  final String inputFrames;
}

/// Все данные из assets, загруженные один раз при старте.
class AppData {
  AppData({
    required this.criteria,
    required this.providers,
    required this.templates,
    required this.reportSchemaText,
  }) : reportSchema = jsonDecode(reportSchemaText) as Map<String, dynamic>;

  /// Сборка из текстов файлов — общая для приложения и тестов.
  factory AppData.fromStrings({
    required String criteriaJson,
    required String providersJson,
    required String reportSchemaJson,
    required String systemPrompt,
    required String userPrompt,
    required String inputVideo,
    required String inputFrames,
  }) =>
      AppData(
        criteria: CriteriaCatalog.fromJson(
            jsonDecode(criteriaJson) as Map<String, dynamic>),
        providers: ProvidersCatalog.fromJson(
            jsonDecode(providersJson) as Map<String, dynamic>),
        templates: PromptTemplates(
          system: systemPrompt,
          user: userPrompt,
          inputVideo: inputVideo,
          inputFrames: inputFrames,
        ),
        reportSchemaText: reportSchemaJson,
      );

  static const assetPaths = (
    criteria: 'assets/criteria.json',
    providers: 'assets/providers.json',
    reportSchema: 'assets/report.schema.json',
    system: 'assets/prompts/analysis_system.md',
    user: 'assets/prompts/analysis_user.md',
    inputVideo: 'assets/prompts/input_video.md',
    inputFrames: 'assets/prompts/input_frames.md',
  );

  static Future<AppData> load([AssetBundle? bundle]) async {
    final b = bundle ?? rootBundle;
    final p = assetPaths;
    final texts = await Future.wait([
      b.loadString(p.criteria),
      b.loadString(p.providers),
      b.loadString(p.reportSchema),
      b.loadString(p.system),
      b.loadString(p.user),
      b.loadString(p.inputVideo),
      b.loadString(p.inputFrames),
    ]);
    return AppData.fromStrings(
      criteriaJson: texts[0],
      providersJson: texts[1],
      reportSchemaJson: texts[2],
      systemPrompt: texts[3],
      userPrompt: texts[4],
      inputVideo: texts[5],
      inputFrames: texts[6],
    );
  }

  final CriteriaCatalog criteria;
  final ProvidersCatalog providers;
  final PromptTemplates templates;
  final String reportSchemaText;
  final Map<String, dynamic> reportSchema;
}
