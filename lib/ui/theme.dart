import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Brand palette: chocolate (#4A2511, sampled from the logo artwork) paired with white.
const kAccent = Color(0xFF4A2511);
const kAccentSoft = Color(0xFF7A4528);
const kOnAccent = Colors.white;
const kSuccess = Color(0xFF2E9E5B);
const kMiss = Color(0xFFC8433F);
const kBackground = Colors.white;
const kSurface = Color(0xFFF5EFE8);
const kSurfaceHigh = Color(0xFFEADFD3);
const kMuted = Color(0xFF7C6B5F);
const kText = Color(0xFF1F1B18);
const kTextSoft = Color(0xFF3D332C);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: kAccent, brightness: Brightness.light).copyWith(
    primary: kAccent,
    onPrimary: kOnAccent,
    surface: kBackground,
    onSurface: kText,
    surfaceContainerHighest: kSurfaceHigh,
    error: kMiss,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: Brightness.light);
  return base.copyWith(
    scaffoldBackgroundColor: kBackground,
    appBarTheme: const AppBarTheme(
      backgroundColor: kBackground,
      foregroundColor: kText,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      systemOverlayStyle: SystemUiOverlayStyle.dark,
    ),
    cardTheme: CardThemeData(
      color: kSurface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: kSurface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: kAccent.withValues(alpha: 0.14),
      iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(color: states.contains(WidgetState.selected) ? kAccent : kMuted)),
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: states.contains(WidgetState.selected) ? kAccent : kMuted)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    // Without this, selected segments take a salmon tint derived from the seed color.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? kAccent : null),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? kOnAccent : kAccent),
        side: WidgetStateProperty.all(const BorderSide(color: kSurfaceHigh)),
      ),
    ),
    textTheme: base.textTheme.apply(bodyColor: kText, displayColor: kText),
  );
}

IconData levelIcon(String name) => switch (name) {
      'spa' => Icons.spa_rounded,
      'music_note' => Icons.music_note_rounded,
      'back_hand' => Icons.back_hand_rounded,
      'sync' => Icons.sync_rounded,
      'graphic_eq' => Icons.graphic_eq_rounded,
      'mic' => Icons.mic_rounded,
      'palette' => Icons.palette_rounded,
      'bolt' => Icons.bolt_rounded,
      'fitness_center' => Icons.fitness_center_rounded,
      'gesture' => Icons.gesture_rounded,
      'local_fire_department' => Icons.local_fire_department_rounded,
      'emoji_events' => Icons.emoji_events_rounded,
      _ => Icons.school_rounded,
    };
