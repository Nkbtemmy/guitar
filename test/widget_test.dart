import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitaro/analytics.dart';
import 'package:guitaro/app_services.dart';
import 'package:guitaro/audio/analysis.dart';
import 'package:guitaro/audio/mic_listener.dart';
import 'package:guitaro/audio/sound_player.dart';
import 'package:guitaro/curriculum/models.dart';
import 'package:guitaro/main.dart';
import 'package:guitaro/music/chord.dart';
import 'package:guitaro/music/chord_library.dart';
import 'package:guitaro/music/notes.dart';
import 'package:guitaro/practice/trackers.dart';
import 'package:guitaro/progress/progress_store.dart';
import 'package:guitaro/sheets/chord_sheet.dart';
import 'package:guitaro/sheets/tab_sequence.dart';
import 'package:guitaro/ui/practice/song_view.dart';
import 'package:guitaro/ui/sheets/tab_player.dart';
import 'package:guitaro/ui/tuner/tuner_panel.dart';
import 'package:guitaro/ui/widgets/neck_view.dart';
import 'package:guitaro/ui/practice/strum_view.dart';
import 'package:guitaro/ui/widgets/chord_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A mic that never touches the platform.
class FakeMic extends MicListener {
  int users = 0;
  final _heard = StreamController<AnalysisFrame>.broadcast();

  @override
  Future<void> acquire() async => users++;

  @override
  Future<void> release() async => users--;

  @override
  Stream<AnalysisFrame> get frames => _heard.stream;

  /// What the mic hears, in a test.
  void hear(AnalysisFrame frame) => _heard.add(frame);
}

/// Plays nothing; keeps which play-along tracks were asked for, as (cache key, bars).
class QuietPlayer extends SoundPlayer {
  final tracks = <(String, int)>[];

  @override
  Future<Duration> playAlongTrack(
      {required String key, required List<Chord> bars, required StrumPattern strum, required int bpm}) async {
    tracks.add((key, bars.length));
    return Duration.zero;
  }

  @override
  Future<Duration> playChords(
          {required String key, required List<Chord> bars, required StrumPattern strum, required int bpm}) async =>
      Duration.zero;

  /// (from, to, listening) of each tab passage asked for, and the click tracks (bars).
  final tabs = <(int, int?, bool)>[];
  final clicks = <int>[];

  @override
  Future<Duration> playTab(String key, TabSequence tab,
      {required int bpm,
      int from = 0,
      int? to,
      int beatsPerBar = 4,
      bool countIn = false,
      bool metronome = false,
      bool listening = false,
      Tuning tuning = Tuning.standard}) async {
    tabs.add((from, to, listening));
    lastTab = tab;
    lastTuning = tuning;
    return Duration.zero;
  }

  TabSequence? lastTab;
  Tuning? lastTuning;

  /// Chords strummed, in order.
  final chords = <Chord>[];

  @override
  Future<Duration> playChord(Chord chord, {bool slow = false}) async {
    chords.add(chord);
    return Duration.zero;
  }

  @override
  Future<Duration> playClickTrack({required int bpm, required int beatsPerBar, required int bars}) async {
    clicks.add(bars);
    return Duration.zero;
  }

  @override
  Future<Duration> playNote(int midi) async => Duration.zero;

  /// Bars of each metronome run asked for.
  final metronomes = <List<int>>[];

  @override
  Future<Duration> playMetronome({required List<int> barBpms, required int beatsPerBar}) async {
    metronomes.add(barBpms);
    return Duration.zero;
  }

  @override
  Future<void> stop() async {}
}

/// Keeps what the app would send as usage stats.
class RecordingAnalytics extends Analytics {
  final sent = <String>[];

  @override
  void tab(String name) => sent.add('tab $name');

  @override
  void lessonStarted(Lesson lesson) => sent.add('start ${lesson.id}');

  @override
  void lessonCompleted(Lesson lesson, int stars) => sent.add('complete ${lesson.id} $stars');
}

Future<(ProgressStore, FakeMic)> pumpApp(WidgetTester tester, {Analytics? analytics}) async {
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
  await tester.pumpWidget(GuitaroApp(services: services, progress: progress, mic: mic, analytics: analytics));
  await tester.pumpAndSettle();
  return (progress, mic);
}

void main() {
  testWidgets('home shows the first lesson and every tab renders', (tester) async {
    final (_, mic) = await pumpApp(tester);
    expect(find.text('Guitaro'), findsOneWidget);
    expect(find.text('Your guitar, up close'), findsWidgets);

    for (final tab in ['Songs', 'Chords', 'Tuner', 'Me', 'Learn']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tab);
    }
    expect(mic.users, 0, reason: 'leaving the tuner releases the mic');
  });

  testWidgets('a lesson can be completed and records progress', (tester) async {
    final analytics = RecordingAnalytics();
    final (progress, _) = await pumpApp(tester, analytics: analytics);
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
    expect(analytics.sent, ['tab Learn', 'start L01-1', 'complete L01-1 2']);
  });

  testWidgets('tabs are counted once per visit, and the Me switch stops usage stats', (tester) async {
    final analytics = RecordingAnalytics();
    final (progress, _) = await pumpApp(tester, analytics: analytics);
    for (final tab in ['Songs', 'Songs', 'Me']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
    }
    expect(analytics.sent, ['tab Learn', 'tab Songs', 'tab Me']);
    expect(progress.shareUsage, isTrue);
    final share = find.text('Share anonymous usage stats');
    await tester.ensureVisible(share);
    await tester.pumpAndSettle();
    await tester.tap(share);
    await tester.pumpAndSettle();
    expect(progress.shareUsage, isFalse);
  });

  testWidgets('a lesson can go back a step', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Your guitar, up close').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Previous step'), findsNothing, reason: 'nothing before the first step');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome!'), findsNothing);
    await tester.tap(find.byTooltip('Previous step'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome!'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue')).onPressed, isNotNull,
        reason: 'a step already done stays done');
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

  testWidgets('every strumming exercise lays out on a narrow phone: sixteenths, chucks, accents, swing',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final progress = ProgressStore(await SharedPreferences.getInstance());
    final services = AppServices(
      library: ChordLibrary.fromJson(File('assets/data/chords.json').readAsStringSync(),
          tipsJson: File('assets/data/chord_tips.json').readAsStringSync()),
      curriculum: Curriculum.fromJson(File('assets/data/curriculum.json').readAsStringSync()),
      player: SoundPlayer(),
    );
    tester.view.physicalSize = const Size(960, 2000); // 320 x 667 points
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final steps = [for (final l in services.curriculum.lessons) ...l.steps.whereType<StrumStep>()];
    expect(steps.map((s) => s.strumPattern.slotsPerBeat), contains(4));
    for (final step in steps) {
      await tester.pumpWidget(MultiProvider(
        providers: [
          Provider.value(value: services),
          ChangeNotifierProvider.value(value: progress),
          ChangeNotifierProvider<MicListener>.value(value: FakeMic()),
        ],
        child: MaterialApp(home: Scaffold(body: StrumView(key: UniqueKey(), step: step, onDone: (_) {}))),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: step.pattern);
      if (step.swing) expect(find.textContaining('Swing'), findsOneWidget);
      if (step.strumPattern.hasAccents) expect(find.text('>'), findsNWidgets(step.strumPattern.hits.where((h) => h.accent).length));
      if (step.strumPattern.slotsPerBeat == 4) expect(find.text('e'), findsNWidgets(step.beatsPerBar));
    }
  });

  testWidgets('a way back: jump to a bar, go back a line, repeat it, and stop', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final progress = ProgressStore(await SharedPreferences.getInstance());
    final player = QuietPlayer();
    final services = AppServices(
      library: ChordLibrary.fromJson(File('assets/data/chords.json').readAsStringSync(),
          tipsJson: File('assets/data/chord_tips.json').readAsStringSync()),
      curriculum: Curriculum.fromJson(File('assets/data/curriculum.json').readAsStringSync()),
      player: player,
    );
    const song = Song(id: 'song', title: 'Song', credit: 'Trad.', bpm: 60, beatsPerBar: 4, pattern: 'D-D-D-D-', lines: [
      SongLine(lyrics: 'one', bars: ['G', 'C', 'G', 'D']),
      SongLine(lyrics: 'two', bars: ['Em', 'C', 'G', 'D']),
    ]);
    tester.view.physicalSize = const Size(1170, 3600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider.value(value: services),
        ChangeNotifierProvider.value(value: progress),
        ChangeNotifierProvider<MicListener>.value(value: FakeMic()),
      ],
      child: const MaterialApp(home: Scaffold(body: SongView(song: song))),
    ));
    await tester.pumpAndSettle();
    // While the song plays its clock ticks every frame, so the screen never settles.
    Future<void> tap(Finder f, {bool playing = false}) async {
      await tester.ensureVisible(f);
      await tester.tap(f);
      if (playing) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      } else {
        await tester.pumpAndSettle();
      }
    }

    // Wait mode: tap a bar to jump there, then back a chord.
    String playNow() => tester.widget<ChordView>(find.byType(ChordView).first).chord.symbol;
    await tap(find.text('Em'));
    expect(playNow(), 'Em');
    await tap(find.text('Back a chord'));
    expect(playNow(), 'D');

    // Play along: tap a bar to start from it.
    await tap(find.descendant(of: find.byType(SegmentedButton<SongMode>), matching: find.text('Play along')));
    await tap(find.text('Em'));
    await tap(find.text('Start from bar 5'), playing: true);
    expect(player.tracks.last, ('song@0:4-8', 4));
    // Back, just after starting the second line, goes to the line before it.
    await tap(find.text('Back'), playing: true);
    expect(player.tracks.last, ('song@0:0-8', 8));
    // Repeat loops the line being played.
    await tap(find.text('Repeat'), playing: true);
    expect(player.tracks.last, ('song@0:0-4', 4));
    await tap(find.text('Stop'));
    expect(find.text('Start: repeat bars 1–4'), findsOneWidget);
    await tap(find.text('Repeat this line'));
    expect(find.text('Start'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  Future<(ProgressStore, FakeMic, QuietPlayer)> pumpWith(WidgetTester tester, Widget home) async {
    SharedPreferences.setMockInitialValues({});
    final progress = ProgressStore(await SharedPreferences.getInstance());
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
        ChangeNotifierProvider<MicListener>.value(value: mic),
      ],
      child: MaterialApp(home: home),
    ));
    await tester.pumpAndSettle();
    return (progress, mic, player);
  }

  testWidgets('the tab player: back and forward a bar, Learn waits, and playing along is listened to', (tester) async {
    final tab = ChordSheet.parse(File('assets/songs/amazing_grace.cho').readAsStringSync(), id: 'ag').tabs.single;
    final (_, mic, player) = await pumpWith(tester, TabPlayerScreen(tab: tab, title: 'Amazing Grace', bpm: 80, beatsPerBar: 3));
    double position() => tester.widget<Slider>(find.byType(Slider)).value;
    final start = position();
    await tester.tap(find.byTooltip('Forward a bar'));
    await tester.pump();
    await tester.tap(find.byTooltip('Forward a bar'));
    await tester.pump();
    final third = tab.events[tab.barStarts[1]].column / TabSequence.columnsPerBeat;
    expect(position(), third, reason: 'two bars on: the start of the third');
    await tester.tap(find.byTooltip('Back a bar'));
    await tester.pump();
    expect(position(), tab.events[tab.barStarts[0]].column / TabSequence.columnsPerBeat);
    expect(position(), greaterThan(start));

    expect(mic.users, 0, reason: 'only Learn listens');
    await tester.tap(find.text('Learn'));
    await tester.pumpAndSettle();
    expect(mic.users, 1);
    expect(find.text('Play the lit note: the tab waits for you.'), findsOneWidget);
    await tester.tap(find.text('Normal'));
    await tester.pumpAndSettle();
    expect(mic.users, 0);

    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(player.tabs.last.$1, tab.barStarts[0], reason: 'plays on from the bar it was at');
    expect(player.tabs.last.$3, isTrue, reason: 'the mic keeps listening to the learner while the tune plays');
    expect(mic.users, 1, reason: 'notes are judged as they pass');
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(mic.users, 0);

    // Without headphones: clicks only, so the mic hears just the learner.
    await tester.ensureVisible(find.text('Play the tune with me'));
    await tester.tap(find.text('Play the tune with me'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 1000));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(player.clicks, hasLength(1));
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the tuner: tap a peg to tune that string, or leave it on Auto', (tester) async {
    await pumpWith(tester, const Scaffold(body: SingleChildScrollView(child: TunerPanel())));
    bool auto() => tester.widget<Switch>(find.byType(Switch)).value;
    expect(auto(), isTrue);
    expect(find.text('Pluck any string'), findsOneWidget);
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(auto(), isFalse);
    expect(find.text('Pluck the A string'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(auto(), isTrue);
    await tester.tap(find.text('How to tune?'));
    await tester.pumpAndSettle();
    expect(find.text('How to tune'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('the drawn neck: headstock on the right, frets closing up towards the body, low E on top', () {
    final open = NeckLayout(const Size(260, 100), baseFret: 1);
    expect(open.headstock, greaterThan(0));
    final widths = [for (var f = 1; f <= 5; f++) open.wire(f - 1) - open.wire(f)];
    expect([for (var i = 1; i < 5; i++) widths[i] < widths[i - 1]].every((closer) => closer), isTrue);
    expect(widths.first / widths[1], closeTo(1.0595, 0.001), reason: 'real fret spacing: the twelfth root of two');
    expect(open.finger(1), greaterThan(open.finger(2)), reason: 'seen from the front, the nut is on the right');
    expect(open.finger(2), lessThan(open.space(2)), reason: 'a fingertip sits just behind its fret');
    expect(open.y(6), lessThan(open.y(1)));
    final up = NeckLayout(const Size(260, 100), baseFret: 5);
    expect((up.headstock, up.nutX), (0, 260), reason: 'up the neck there is no headstock');
  });

  testWidgets('Learn waits for the right note, unless Keep playing is on: then a wrong note moves on', (tester) async {
    final tab = ChordSheet.parse(File('assets/songs/amazing_grace.cho').readAsStringSync(), id: 'ag').tabs.single;
    final (progress, mic, _) = await pumpWith(tester, TabPlayerScreen(tab: tab, title: 'Amazing Grace', bpm: 80, beatsPerBar: 3));
    double position() => tester.widget<Slider>(find.byType(Slider)).value;
    double beat(int i) => tab.events[i].column / TabSequence.columnsPerBeat;
    var t = 0.0;
    // A fresh pluck of [midi], then the note ringing on clearly.
    Future<void> pluck(int midi) async {
      final f = midiToFreq(midi);
      for (var k = 0; k < 3; k++) {
        t += 0.05;
        mic.hear(AnalysisFrame(
            time: t, rms: 0.1, pitch: PitchResult(f, 1), peaks: [SpectralPeak(f, 1)], onsets: k == 0 ? [t - 0.01] : const []));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('Learn'));
    await tester.pumpAndSettle();
    final first = tab.events[0].midiNotes.first;
    await pluck(first + 2);
    expect(position(), beat(0), reason: 'Learn waits for the right note');
    await tester.tap(find.text('Keep playing when I miss'));
    await tester.pumpAndSettle();
    expect(progress.keepPlaying, isTrue);
    await pluck(first + 2);
    expect(position(), beat(1), reason: 'keeping going: a wrong note moves on');
    await pluck(tab.events[1].midiNotes.first);
    expect(position(), beat(2), reason: 'and so does the right one');
    expect(tester.takeException(), isNull);
  });
}
