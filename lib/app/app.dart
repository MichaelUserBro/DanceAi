import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../theme/stage_theme.dart';
import '../ui/widgets/stage_background.dart';

class DanceAiApp extends StatefulWidget {
  const DanceAiApp({super.key});

  @override
  State<DanceAiApp> createState() => _DanceAiAppState();
}

class _DanceAiAppState extends State<DanceAiApp> {
  late final Future<AppData> _data = AppData.load();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DanceAI',
      debugShowCheckedModeBanner: false,
      theme: buildStageTheme(),
      home: FutureBuilder<AppData>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return _Fatal(error: '${snap.error}');
          }
          if (!snap.hasData) {
            return const StageBackground(child: SizedBox.expand());
          }
          return StageBackground(
            child: Center(
              child: Text('DanceAI', style: StageText.display(40)),
            ),
          );
        },
      ),
    );
  }
}

class _Fatal extends StatelessWidget {
  const _Fatal({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) => StageBackground(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Не удалось загрузить данные приложения.\n$error',
                textAlign: TextAlign.center, style: StageText.body(15)),
          ),
        ),
      );
}
