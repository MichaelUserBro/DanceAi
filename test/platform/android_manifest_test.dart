import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Страховка: release-APK собирается из src/main. INTERNET в src/debug и
// src/profile туда не попадает — без него анализ падает «Failed host lookup».
void main() {
  test('src/main/AndroidManifest.xml: разрешение INTERNET', () {
    final xml =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final withoutComments = xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    expect(
      withoutComments,
      matches(RegExp(
          r'<uses-permission\s+android:name="android\.permission\.INTERNET"\s*/>')),
    );
  });
}
