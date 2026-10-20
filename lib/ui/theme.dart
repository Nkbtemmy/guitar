import 'package:flutter/material.dart';

const kAccent = Color(0xFFFF9F43);
const kSuccess = Color(0xFF5BD68A);
const kMiss = Color(0xFFF2726F);
const kBackground = Color(0xFF14110F);
const kSurface = Color(0xFF1F1A17);
const kSurfaceHigh = Color(0xFF2A2420);
const kMuted = Color(0xFFA89F97);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: kAccent, brightness: Brightness.dark).copyWith(
    primary: kAccent,
    onPrimary: const Color(0xFF231300),
    surface: kSurface,
    surfaceContainerHighest: kSurfaceHigh,
    error: kMiss,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: Brightness.dark);
  return base.copyWith(
    scaffoldBackgroundColor: kBackground,
    appBarTheme: const AppBarTheme(backgroundColor: kBackground, elevation: 0, centerTitle: false),
    cardTheme: CardThemeData(
      color: kSurface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: kSurface,
      indicatorColor: kAccent.withValues(alpha: 0.18),
      labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    textTheme: base.textTheme.apply(bodyColor: const Color(0xFFF3ECE6), displayColor: const Color(0xFFF3ECE6)),
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
