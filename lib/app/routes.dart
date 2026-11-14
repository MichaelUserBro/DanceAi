import 'package:material_ui/material_ui.dart';

/// Переход «выход на сцену»: новый экран проявляется, слегка поднимаясь
/// и приближаясь. Если в системе отключены анимации — без задержки.
Route<T> stageRoute<T>(Widget page, {bool replace = false}) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 420),
    reverseTransitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      if (MediaQuery.of(context).disableAnimations) return child;
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      final outgoing = CurvedAnimation(
        parent: secondaryAnimation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.035), end: Offset.zero)
              .animate(curved),
          child: ScaleTransition(
            scale: Tween(begin: 0.985, end: 1.0).animate(curved),
            child: FadeTransition(
              opacity: Tween(begin: 1.0, end: 0.6).animate(outgoing),
              child: child,
            ),
          ),
        ),
      );
    },
  );
}
