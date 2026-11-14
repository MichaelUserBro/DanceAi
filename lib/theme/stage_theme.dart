import 'package:material_ui/material_ui.dart';

import '../data/criteria.dart';
import '../report/report.dart';

/// Палитра тёмной «сцены» (spec 8а).
abstract final class StageColors {
  static const background = Color(0xFF0B0A12);
  static const backgroundDeep = Color(0xFF07060C);
  static const surface = Color(0xFF15131F);
  static const surfaceHigh = Color(0xFF1F1B2D);
  static const outline = Color(0x22FFFFFF);

  static const textPrimary = Color(0xFFF5F1EA);
  static const textSecondary = Color(0xFFB0A9C2);
  static const textMuted = Color(0xFF746E88);

  /// Нейтральный «прожектор» приложения.
  static const spotlight = Color(0xFF9C8CFF);
  static const spotlightWarm = Color(0xFFFFC98A);

  static const good = Color(0xFF5FD3A0);
  static const partial = Color(0xFFF2C14E);
  static const poor = Color(0xFFFF6B6B);
  static const notVisible = Color(0xFF7D7890);

  static const critical = Color(0xFFFF5A6E);
  static const major = Color(0xFFFFA94D);
  static const minor = Color(0xFF8FA3BF);

  static const leader = Color(0xFF6EC6FF);
  static const follower = Color(0xFFFF8FD0);

  static Color verdict(Verdict v) => switch (v) {
        Verdict.good => good,
        Verdict.partial => partial,
        Verdict.poor => poor,
        Verdict.notVisible => notVisible,
      };

  static Color severity(Severity s) => switch (s) {
        Severity.critical => critical,
        Severity.major => major,
        Severity.minor => minor,
      };

  static Color who(Who w, DanceAccent accent) => switch (w) {
        Who.leader => leader,
        Who.follower => follower,
        Who.couple => accent.primary,
      };
}

/// Акцент стиля: Стандарт — золото и шампань, Латина — коралл и огонь.
class DanceAccent {
  const DanceAccent._(this.primary, this.secondary, this.glow);

  static const standard =
      DanceAccent._(Color(0xFFE8C27A), Color(0xFFF7E3B5), Color(0xFFB8893A));
  static const latin =
      DanceAccent._(Color(0xFFFF4D7E), Color(0xFFFF9A3C), Color(0xFFD02A5C));
  static const neutral = DanceAccent._(
      StageColors.spotlight, Color(0xFFC9BFFF), Color(0xFF5B4BD6));

  static DanceAccent of(DanceStyle style) => switch (style) {
        DanceStyle.standard => standard,
        DanceStyle.latin => latin,
      };

  final Color primary;
  final Color secondary;
  final Color glow;

  LinearGradient get gradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [primary, secondary],
      );
}

/// Типографика: Playfair Display — заголовки и цифры, Manrope — текст.
/// Шрифты переменные: вес задаётся и через fontWeight, и через ось wght.
abstract final class StageText {
  static const _body = 'Manrope';
  static const _display = 'PlayfairDisplay';

  static TextStyle _style(String family, double size, int weight,
          {double? height, double? letterSpacing, Color? color}) =>
      TextStyle(
        fontFamily: family,
        fontSize: size,
        fontWeight: FontWeight.values[(weight ~/ 100) - 1],
        fontVariations: [FontVariation.weight(weight.toDouble())],
        height: height,
        letterSpacing: letterSpacing,
        color: color ?? StageColors.textPrimary,
      );

  static TextStyle display(double size, {int weight = 700, Color? color}) =>
      _style(_display, size, weight, height: 1.1, color: color);

  static TextStyle body(double size,
          {int weight = 400, Color? color, double height = 1.45}) =>
      _style(_body, size, weight, height: height, color: color);

  static TextStyle label(double size, {int weight = 600, Color? color}) =>
      _style(_body, size, weight,
          letterSpacing: 0.4, height: 1.2, color: color);

  static TextTheme textTheme() => TextTheme(
        displayLarge: display(48),
        displayMedium: display(38),
        displaySmall: display(30),
        headlineLarge: display(28),
        headlineMedium: display(24),
        headlineSmall: display(20),
        titleLarge: body(19, weight: 700),
        titleMedium: body(16, weight: 600),
        titleSmall: body(14, weight: 600),
        bodyLarge: body(16),
        bodyMedium: body(14.5),
        bodySmall: body(12.5, color: StageColors.textSecondary),
        labelLarge: label(15),
        labelMedium: label(13),
        labelSmall: label(11.5),
      );
}

ThemeData buildStageTheme() {
  const scheme = ColorScheme.dark(
    primary: StageColors.spotlight,
    onPrimary: StageColors.backgroundDeep,
    secondary: StageColors.spotlightWarm,
    onSecondary: StageColors.backgroundDeep,
    surface: StageColors.surface,
    onSurface: StageColors.textPrimary,
    surfaceContainerHighest: StageColors.surfaceHigh,
    outline: StageColors.outline,
    error: StageColors.poor,
  );
  final text = StageText.textTheme();
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: StageColors.background,
    canvasColor: StageColors.background,
    fontFamily: 'Manrope',
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: StageText.display(22),
      foregroundColor: StageColors.textPrimary,
    ),
    dividerColor: StageColors.outline,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: StageColors.surfaceHigh,
      labelStyle: StageText.body(14, color: StageColors.textSecondary),
      hintStyle: StageText.body(14, color: StageColors.textMuted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: StageColors.spotlight, width: 1.4),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected)
              ? StageColors.backgroundDeep
              : StageColors.textSecondary),
      trackColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected)
              ? StageColors.spotlight
              : StageColors.surfaceHigh),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: StageColors.surfaceHigh,
      contentTextStyle: StageText.body(14),
      behavior: SnackBarBehavior.floating,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: StageColors.spotlight,
        textStyle: StageText.label(14),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}
