import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Версия FFmpeg в ffmpeg_kit_flutter_new_min 3.6.8 и ссылки на исходники
/// (LGPL требует дать доступ к исходному коду используемой версии).
const ffmpegVersion = '8.1.2';
const ffmpegSourceUrl = 'https://github.com/arthenica/FFmpeg/tree/n8.1.2';
const ffmpegKitSourceUrl = 'https://github.com/sk3llo/ffmpeg-kit';

/// Текст LGPL 3.0 самой обёртки Flutter добавляет автоматически
/// (LICENSE пакета ffmpeg_kit_flutter_new_min).
const ffmpegKitFlutterSourceUrl = 'https://github.com/sk3llo/ffmpeg_kit_flutter';

const ffmpegNotice = 'Приложение использует FFmpeg $ffmpegVersion '
    '(https://ffmpeg.org) — без изменений, в виде отдельных динамических '
    'библиотек, лицензия GNU LGPL 2.1 или новее. Исходный код этой версии: '
    '$ffmpegSourceUrl\n\n'
    'Обёртка FFmpegKit (ffmpeg_kit_flutter_new_min 3.6.8) — лицензия GNU '
    'LGPL 3.0. Исходный код: $ffmpegKitFlutterSourceUrl и $ffmpegKitSourceUrl\n\n'
    'Сборка без GPL-компонентов. Библиотеки FFmpeg можно заменить своей '
    'совместимой сборкой.';

/// Добавляет на стандартную страницу лицензий Flutter то, что не попадает
/// туда автоматически: FFmpeg (LGPL) и встроенные шрифты (OFL).
void registerAppLicenses() {
  LicenseRegistry.addLicense(() async* {
    Future<String> text(String name) =>
        rootBundle.loadString('assets/licenses/$name');
    yield LicenseEntryWithLineBreaks(const ['FFmpeg'], ffmpegNotice);
    yield LicenseEntryWithLineBreaks(
        const ['FFmpeg'], await text('LGPL-2.1.txt'));
    yield LicenseEntryWithLineBreaks(
        const ['Manrope'], await text('OFL-Manrope.txt'));
    yield LicenseEntryWithLineBreaks(
        const ['Playfair Display'], await text('OFL-PlayfairDisplay.txt'));
  });
}
