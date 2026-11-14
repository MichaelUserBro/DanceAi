import 'package:dance_ai/app/app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('приложение запускается без ошибок', (tester) async {
    await tester.pumpWidget(const DanceAiApp());
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });
}
