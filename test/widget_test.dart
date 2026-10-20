import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fretwise/app_services.dart';
import 'package:fretwise/audio/mic_listener.dart';
import 'package:fretwise/audio/sound_player.dart';
import 'package:fretwise/curriculum/models.dart';
import 'package:fretwise/main.dart';
import 'package:fretwise/music/chord_library.dart';
import 'package:fretwise/progress/progress_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A mic that never touches the platform.
class FakeMic extends MicListener {
  int users = 0;

  @override
  Future<void> acquire() async => users++;

  @override
  Future<void> release() async => users--;
}

Future<(ProgressStore, FakeMic)> pumpApp(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final progress = ProgressStore(await SharedPreferences.getInstance());
  final mic = FakeMic();
  final services = AppServices(
    library: ChordLibrary.fromJson(File('assets/data/chords.json').readAsStringSync(),
        tipsJson: File('assets/data/chord_tips.json').readAsStringSync()),
    curriculum: Curriculum.fromJson(File('assets/data/curriculum.json').readAsStringSync()),
    player: SoundPlayer(),
  );
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(FretwiseApp(services: services, progress: progress, mic: mic));
  await tester.pumpAndSettle();
  return (progress, mic);
}

void main() {
  testWidgets('home shows the first lesson and every tab renders', (tester) async {
    final (_, mic) = await pumpApp(tester);
    expect(find.text('Fretwise'), findsOneWidget);
    expect(find.text('Your guitar, up close'), findsWidgets);

    for (final tab in ['Songs', 'Chords', 'Tuner', 'Me', 'Learn']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tab);
    }
    expect(mic.users, 0, reason: 'leaving the tuner releases the mic');
  });

  testWidgets('a lesson can be completed and records progress', (tester) async {
    final (progress, _) = await pumpApp(tester);
    await tester.tap(find.text('Your guitar, up close').first);
    await tester.pumpAndSettle();
    expect(find.text('Welcome!'), findsOneWidget);

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('The headstock'));
    await tester.pumpAndSettle();
    expect(find.text('Not quite. Try another answer.'), findsOneWidget);
    await tester.tap(find.text('The bridge'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();

    expect(find.text('Lesson complete!'), findsOneWidget);
    expect(progress.isComplete('L01-1'), isTrue);
    expect(progress.starsFor('L01-1'), 2, reason: 'one wrong quiz answer');
    expect(find.text('Next: The six strings'), findsOneWidget);
  });

  testWidgets('listening steps hold the mic and can be skipped', (tester) async {
    final (progress, mic) = await pumpApp(tester);
    progress.unlockAll = true;
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('E minor'), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('E minor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Play Em'), findsOneWidget);
    expect(mic.users, 1);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(mic.users, 0);
    expect(find.text('Troubleshooting a chord'), findsOneWidget);
  });
}
