import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitaro/app_services.dart';
import 'package:guitaro/audio/mic_listener.dart';
import 'package:guitaro/curriculum/models.dart';
import 'package:guitaro/audio/analysis.dart';
import 'package:guitaro/music/notes.dart';
import 'package:guitaro/music/chord_library.dart';
import 'package:guitaro/practice/metronome.dart';
import 'package:guitaro/progress/practice_log.dart';
import 'package:guitaro/progress/progress_store.dart';
import 'package:guitaro/practice/ear.dart';
import 'package:guitaro/ui/practice/chord_challenge_screen.dart';
import 'package:guitaro/ui/practice/ear_training_screen.dart';
import 'package:guitaro/ui/practice/fretboard_game_screen.dart';
import 'package:guitaro/ui/widgets/fretboard.dart';
import 'package:guitaro/ui/practice/metronome_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show FakeMic, QuietPlayer;

/// Pumps [home] with everything the practice tools read.
Future<(ProgressStore, PracticeLog, FakeMic, QuietPlayer)> pumpTool(WidgetTester tester, Widget home) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final progress = ProgressStore(prefs);
  final practice = PracticeLog(prefs);
  final mic = FakeMic();
  final player = QuietPlayer();
  final services = AppServices(
    library: ChordLibrary.fromJson(File('assets/data/chords.json').readAsStringSync(),
        tipsJson: File('assets/data/chord_tips.json').readAsStringSync()),
    curriculum: Curriculum.fromJson(File('assets/data/curriculum.json').readAsStringSync()),
    player: player,
  );
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [
      Provider.value(value: services),
      ChangeNotifierProvider.value(value: progress),
      ChangeNotifierProvider.value(value: practice),
      ChangeNotifierProvider<MicListener>.value(value: mic),
    ],
    child: MaterialApp(home: home),
  ));
  await tester.pumpAndSettle();
  return (progress, practice, mic, player);
}

void main() {
  group('metronome', () {
    test('a steady run, and a speed trainer stepping up to its goal and holding there', () {
      final steady = MetronomePlan.steady(bpm: 120, beatsPerBar: 4, seconds: 60);
      expect(steady.bars, everyElement(120));
      expect(steady.seconds, 60);
      final trainer = MetronomePlan.trainer(from: 60, to: 80, step: 10, barsPerStep: 2, beatsPerBar: 4, holdSeconds: 6);
      expect(trainer.bars, [60, 60, 70, 70, 80, 80]);
      expect(trainer.at(0), (bar: 0, bpm: 60, beat: 0));
      expect(trainer.at(1.5), (bar: 0, bpm: 60, beat: 1));
      expect(trainer.at(8), (bar: 2, bpm: 70, beat: 0), reason: 'two bars of 60 last 8 seconds');
    });

    test('tap tempo averages the last taps, and a long pause starts over', () {
      final taps = TapTempo();
      expect(taps.tap(Duration.zero), isNull);
      expect(taps.tap(const Duration(milliseconds: 500)), 120);
      expect(taps.tap(const Duration(milliseconds: 1010)), 119);
      expect(taps.tap(const Duration(seconds: 5)), isNull, reason: 'a pause: a new tempo');
      expect(taps.tap(const Duration(milliseconds: 5750)), 80);
    });

    testWidgets('start, change the tempo while it plays, and the trainer steps up', (tester) async {
      final (_, _, _, player) = await pumpTool(tester, const MetronomeScreen());
      await tester.tap(find.text('Start'));
      await tester.pump();
      expect(player.metronomes.last, everyElement(80));
      await tester.tap(find.byTooltip('Faster'));
      await tester.pump();
      expect(player.metronomes.last, everyElement(81), reason: 'a new tempo plays straight away');
      await tester.tap(find.text('Speed trainer'));
      await tester.pump();
      expect(player.metronomes.last.take(5), [81, 81, 81, 81, 86]);
      expect(player.metronomes.last.last, 120);
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(find.text('Start'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('chord changes: pick a pair, count in, a minute listening, and the result is kept', (tester) async {
    final (_, practice, mic, _) = await pumpTool(tester, const ChordChallengeScreen(length: Duration(seconds: 5)));
    await tester.tap(find.text('A – D'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start: 5 seconds'));
    await tester.pump();
    expect(find.text('Get ready'), findsOneWidget);
    expect(mic.users, 1, reason: 'the mic warms up during the count-in');
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('changes'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('0 changes'), findsOneWidget);
    expect(mic.users, 0);
    expect(practice.changeRuns('D', 'A').single.count, 0);
    expect(tester.takeException(), isNull);
  });

  group('fretboard notes', () {
    testWidgets('name it: tap the note at the dot; the score and best are kept', (tester) async {
      final (_, practice, _, _) = await pumpTool(tester, FretboardGameScreen(length: const Duration(seconds: 10), random: math.Random(3)));
      await tester.tap(find.text('Start: 10 seconds'));
      await tester.pump();
      String answer() => noteName(tester.widget<Fretboard>(find.byType(Fretboard)).target.midi);
      await tester.tap(find.text(answer()));
      await tester.pump();
      expect(find.text('Yes!'), findsOneWidget);
      expect(find.text('Score 1'), findsOneWidget);
      final right = answer();
      await tester.tap(find.text(right == 'C' ? 'D' : 'C'));
      await tester.pump();
      expect(find.text('That was $right.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(find.text('1 right of 2'), findsOneWidget);
      expect(practice.best('fretboard:name'), 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('play it: find the note on the string named, and the mic hears it', (tester) async {
      final (_, _, mic, _) = await pumpTool(tester, FretboardGameScreen(length: const Duration(seconds: 10), random: math.Random(5)));
      await tester.tap(find.text('Play it'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start: 10 seconds'));
      await tester.pump();
      expect(mic.users, 1);
      final prompt = tester.widget<Text>(find.textContaining(RegExp(r'^Play [A-G]#?$'))).data!.substring(5);
      final string = int.parse(RegExp(r'string (\d)').firstMatch(tester.widget<Text>(find.textContaining('(string ')).data!)!.group(1)!);
      final midi = [for (var f = 0; f <= 12; f++) midiAt(string, f)].firstWhere((m) => noteName(m) == prompt);
      final freq = midiToFreq(midi);
      mic.hear(AnalysisFrame(time: 1, rms: 0.1, pitch: PitchResult(freq, 1), peaks: [SpectralPeak(freq, 1)]));
      await tester.pump();
      expect(find.text('Score 1'), findsOneWidget);
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(mic.users, 0);
      expect(tester.takeException(), isNull);
    });
  });

  group('ear training', () {
    test('phrases step through the open-position scale, and play as quarter notes', () {
      final phrase = echoPhrase(5, math.Random(1));
      expect(phrase, hasLength(5));
      final steps = [for (var i = 1; i < 5; i++) (echoNotes.indexOf(phrase[i]) - echoNotes.indexOf(phrase[i - 1])).abs()];
      expect(steps.every((s) => s == 1 || s == 2), isTrue, reason: '$steps');
      final tab = phraseTab(phrase);
      expect([for (final e in tab.events) e.column], [0, 4, 8, 12, 16]);
    });

    testWidgets('major or minor: hear it, answer, ten chords, and the best is kept', (tester) async {
      final (_, practice, _, player) = await pumpTool(tester, EarTrainingScreen(random: math.Random(2)));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 10; i++) {
        final major = majorChords.contains(player.chords.last.id);
        // Right on all but the last.
        await tester.tap(find.text(major == (i < 9) ? 'Major' : 'Minor'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(i < 9 ? 'Next chord' : 'See my score'));
        await tester.pumpAndSettle();
      }
      expect(find.text('9 of 10 right'), findsOneWidget);
      expect(practice.best('ear:quality'), 9);
    });

    testWidgets('play it back: each note heard turns from ? to its name', (tester) async {
      final (_, _, mic, player) = await pumpTool(tester, EarTrainingScreen(random: math.Random(4)));
      await tester.tap(find.text('Play it back'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(mic.users, 1);
      var t = 0.0;
      for (final e in player.lastTab!.events) {
        final f = midiToFreq(e.midiNotes.single);
        for (var k = 0; k < 2; k++) {
          t += 0.05;
          mic.hear(AnalysisFrame(time: t, rms: 0.1, pitch: PitchResult(f, 1), peaks: [SpectralPeak(f, 1)], onsets: k == 0 ? [t - 0.01] : const []));
          await tester.pump();
        }
      }
      await tester.pumpAndSettle();
      expect(find.text('Yes! Played back.'), findsOneWidget);
      expect(find.text('?'), findsNothing);
      await tester.tap(find.text('Finish'));
      await tester.pumpAndSettle();
      expect(find.text('1 phrase played back'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
