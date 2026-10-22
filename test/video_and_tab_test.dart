import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitaro/app_services.dart';
import 'package:guitaro/audio/mic_listener.dart';
import 'package:guitaro/audio/sound_player.dart';
import 'package:guitaro/curriculum/models.dart';
import 'package:guitaro/main.dart';
import 'package:guitaro/music/chord_library.dart';
import 'package:guitaro/music/notes.dart';
import 'package:guitaro/progress/progress_store.dart';
import 'package:guitaro/ui/widgets/chord_diagram.dart';
import 'package:guitaro/ui/widgets/chord_view.dart';
import 'package:guitaro/ui/widgets/tab_staff.dart';
import 'package:guitaro/video/video_catalog.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

final library = ChordLibrary.fromJson(File('assets/data/chords.json').readAsStringSync(),
    tipsJson: File('assets/data/chord_tips.json').readAsStringSync());
final curriculum = Curriculum.fromJson(File('assets/data/curriculum.json').readAsStringSync());

/// Pretends every video loads instantly as a 60 s clip.
class FakeVideoPlatform extends VideoPlayerPlatform {
  final calls = <String>[];
  final _events = <int, StreamController<VideoEvent>>{};
  int _next = 0;

  int _create() {
    final id = _next++;
    final c = _events[id] = StreamController<VideoEvent>();
    scheduleMicrotask(() => c.add(VideoEvent(
        eventType: VideoEventType.initialized, duration: const Duration(seconds: 60), size: const Size(1280, 720))));
    return id;
  }

  @override
  Future<void> init() async {}
  @override
  Future<int?> create(DataSource dataSource) async => _create();
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    calls.add('open ${options.dataSource.asset ?? options.dataSource.uri}');
    return _create();
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;
  @override
  Future<void> play(int playerId) async => calls.add('play');
  @override
  Future<void> pause(int playerId) async => calls.add('pause');
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> dispose(int playerId) async => calls.add('dispose');
  @override
  Widget buildView(int playerId) => const ColoredBox(color: Colors.black);
  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const ColoredBox(color: Colors.black);
}

class SilentMic extends MicListener {
  @override
  Future<void> acquire() async {}
  @override
  Future<void> release() async {}
}

void main() {
  group('tab', () {
    test('a chord column has one fret per sounding string and x for muted strings', () {
      final c = TabColumn.chord(library.byId('C'));
      expect([for (var s = 1; s <= 6; s++) c.textFor(s)], ['0', '1', '0', '2', '3', 'x']);
      expect(c.label, 'C');
      final barre = TabColumn.chord(library.byId('Bm'));
      expect([for (var s = 1; s <= 6; s++) barre.textFor(s)], ['2', '3', '4', '4', '2', 'x']);
    });

    test('a note column marks only its string', () {
      final c = TabColumn.note(const FretNote(3, 7));
      expect([for (var s = 1; s <= 6; s++) c.textFor(s)], [null, null, '7', null, null, null]);
    });

    testWidgets('long tabs scroll instead of overflowing', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: TabStaff(columns: [for (var i = 0; i < 20; i++) TabColumn.note(FretNote(1, i % 5))], current: 15),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });
  });

  testWidgets('chord display follows the setting', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final progress = ProgressStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: progress,
      child: MaterialApp(home: Scaffold(body: Center(child: ChordView(chord: library.byId('G'))))),
    ));
    expect(find.byType(ChordDiagram), findsOneWidget);
    expect(find.byType(TabStaff), findsOneWidget);
    progress.chordDisplay = ChordDisplay.tab;
    await tester.pump();
    expect(find.byType(ChordDiagram), findsNothing);
    expect(find.byType(TabStaff), findsOneWidget);
    progress.chordDisplay = ChordDisplay.diagram;
    await tester.pump();
    expect(find.byType(TabStaff), findsNothing);
  });

  group('videos', () {
    const index = '[{"id": "lesson-L01-1", "kind": "lesson", "title": "Your guitar, up close", "subtitle": "s", '
        '"levelId": "L01", "lessonId": "L01-1", "duration": 61.5, "file": "lesson-L01-1.mp4", "poster": "lesson-L01-1.jpg"}, '
        '{"id": "intro-L01", "kind": "intro", "title": "Level 1: Zero", "subtitle": "Meet your guitar", '
        '"levelId": "L01", "duration": 40, "file": "intro-L01.mp4", "poster": "intro-L01.jpg"}]';

    test('catalog maps lessons and level intros', () {
      final catalog = VideoCatalog.fromJson(index);
      expect(catalog.forLesson('L01-1')!.duration, const Duration(milliseconds: 61500));
      expect(catalog.introFor('L01')!.title, 'Level 1: Zero');
      expect(catalog.forLesson('L01-2'), isNull);
    });

    testWidgets('a lesson opens with its video, which never blocks and never costs stars', (tester) async {
      final fake = FakeVideoPlatform();
      VideoPlayerPlatform.instance = fake;
      SharedPreferences.setMockInitialValues({});
      final progress = ProgressStore(await SharedPreferences.getInstance());
      final services = AppServices(
        library: library,
        curriculum: curriculum,
        player: SoundPlayer(),
        videos: VideoCatalog.fromJson(index),
      );
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(GuitaroApp(services: services, progress: progress, mic: SilentMic()));
      await tester.pumpAndSettle();
      expect(find.text('Intro'), findsOneWidget, reason: 'level 1 has an intro video');
      // Screen readers must hear a plain button: an ActionChip here carried a "selected" state,
      // which Flutter web announces as a checkbox.
      final semantics = tester.ensureSemantics();
      expect(tester.getSemantics(find.widgetWithText(OutlinedButton, 'Intro')),
          isSemantics(isButton: true, hasSelectedState: false, hasCheckedState: false));
      semantics.dispose();

      await tester.tap(find.text('Your guitar, up close').first);
      await tester.pumpAndSettle();
      expect(find.text('WATCH'), findsOneWidget);
      expect(fake.calls, containsAllInOrder(['open assets/videos/lesson-L01-1.mp4', 'play']));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      // Controller disposal finishes on the real event loop.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(fake.calls, contains('dispose'));
      expect(find.text('Welcome!'), findsOneWidget);

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('The bridge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Finish'));
      await tester.pumpAndSettle();
      expect(progress.starsFor('L01-1'), 3);
    });
  });

  test('rendered video index matches the files and lessons', () {
    final file = File('assets/videos/index.json');
    if (!file.existsSync()) return markTestSkipped('videos not rendered yet');
    final entries = (jsonDecode(file.readAsStringSync()) as List).cast<Map<String, dynamic>>();
    final lessonIds = curriculum.lessons.map((l) => l.id).toSet();
    final levelIds = curriculum.levels.map((l) => l.id).toSet();
    for (final e in entries) {
      expect(File('assets/videos/${e['file']}').existsSync(), isTrue, reason: '${e['file']} missing');
      expect(File('assets/videos/${e['poster']}').existsSync(), isTrue, reason: '${e['poster']} missing');
      expect(levelIds, contains(e['levelId']));
      if (e['lessonId'] != null) expect(lessonIds, contains(e['lessonId']));
    }
  });

  test('video scripts only reference real chords and songs', () {
    final dir = Directory('content/videos');
    if (!dir.existsSync()) return markTestSkipped('no scripts yet');
    for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
      final v = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      for (final s in (v['scenes'] as List).cast<Map<String, dynamic>>()) {
        expect((s['lines'] as List), isNotEmpty, reason: '${v['id']} ${s['type']} has no narration');
        for (final c in [s['chord'], ...?(s['chords'] as List?)].whereType<String>()) {
          expect(library.contains(c), isTrue, reason: '${v['id']} uses $c');
        }
        if (s['song'] != null) expect(curriculum.songs.containsKey(s['song']), isTrue);
      }
    }
  });
}
