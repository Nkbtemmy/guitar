import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitaro/app_services.dart';
import 'package:guitaro/curriculum/models.dart';
import 'package:guitaro/main.dart';
import 'package:guitaro/music/chord_library.dart';
import 'package:guitaro/progress/practice_log.dart';
import 'package:guitaro/progress/progress_store.dart';
import 'package:guitaro/ui/practice/song_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show FakeMic, QuietPlayer;

void main() {
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  const grace = SpotPlace.song('amazing_grace');
  void miss(PracticeLog log, int from, {bool right = false, DateTime? now}) =>
      log.recordSpot(grace, from: from, to: from + 4, title: 'Amazing Grace', detail: 'Bars ${from + 1}–${from + 4}', right: right, now: now);

  group('weak spots', () {
    test('bars count towards their line; the most missed comes first, and getting it right takes it off', () {
      final log = PracticeLog(prefs);
      miss(log, 4);
      miss(log, 4);
      miss(log, 8);
      miss(log, 0, right: true);
      expect([for (final s in log.weakSpots()) s.from], [4, 8], reason: 'a line only played right is not weak');
      expect(log.weakSpots().first.misses, 2);
      for (var i = 0; i < 3; i++) {
        miss(log, 4, right: true);
      }
      expect([for (final s in log.weakSpots()) s.from], [8], reason: 'practised right since: fixed');
    });

    test('they are kept, forgotten after a month unplayed, and a damaged one does not lose the rest', () async {
      final log = PracticeLog(prefs);
      miss(log, 4, now: DateTime(2026, 9, 1));
      miss(log, 8);
      final again = PracticeLog(prefs);
      expect([for (final s in again.weakSpots()) s.from], [8], reason: 'bar 5 was last played two months ago');
      expect(again.weakSpots(now: DateTime(2026, 9, 10)).map((s) => s.from), contains(4));
      again.forget(again.weakSpots().single);
      expect(PracticeLog(prefs).weakSpots(), isEmpty);

      SharedPreferences.setMockInitialValues({
        'practice.v1': '{"spots": [{"place": {"k": "nonsense"}}, {"place": {"k": "song", "id": "x", "i": 0}, "from": 0, '
            '"to": 4, "title": "X", "detail": "d", "misses": 2, "hits": 0, "last": ${DateTime.now().millisecondsSinceEpoch}}]}',
      });
      expect(PracticeLog(await SharedPreferences.getInstance()).weakSpots().single.title, 'X');
      SharedPreferences.setMockInitialValues({'practice.v1': 'not json'});
      final damaged = await SharedPreferences.getInstance();
      expect(PracticeLog(damaged).weakSpots(), isEmpty);
      expect(damaged.getString('practice.v1.damaged'), 'not json');
    });
  });

  test('chord-change minutes: either way round is one pair, with its best and its history', () {
    final log = PracticeLog(prefs);
    expect(log.recordChanges('C', 'G', 14, now: DateTime(2026, 10, 1)), isTrue, reason: 'the first minute is a best');
    expect(log.recordChanges('G', 'C', 12, now: DateTime(2026, 10, 2)), isFalse);
    expect(log.recordChanges('C', 'G', 21, now: DateTime(2026, 10, 3)), isTrue);
    log.recordChanges('A', 'D', 9, now: DateTime(2026, 9, 1));
    final again = PracticeLog(prefs);
    expect(again.bestChanges('G', 'C'), 21);
    expect([for (final r in again.changeRuns('C', 'G')) r.count], [14, 12, 21]);
    expect(again.lastChangePair, ('C', 'G'));
    expect(again.bestChanges('Em', 'Am'), isNull);
  });

  testWidgets('a weak spot opens its song in play-along, looping its line', (tester) async {
    final log = PracticeLog(prefs);
    miss(log, 4);
    final services = AppServices(
      library: ChordLibrary.fromJson(File('assets/data/chords.json').readAsStringSync(),
          tipsJson: File('assets/data/chord_tips.json').readAsStringSync()),
      curriculum: Curriculum.fromJson(File('assets/data/curriculum.json').readAsStringSync()),
      player: QuietPlayer(),
    );
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(GuitaroApp(services: services, progress: ProgressStore(prefs), mic: FakeMic(), practice: log));
    await tester.pumpAndSettle();
    expect(find.text('1 to fix'), findsOneWidget);
    await tester.tap(find.text('Practise these'));
    await tester.pumpAndSettle();
    expect(find.text('Bars 5–8\nMissed 1 of 1 · today'), findsOneWidget);
    await tester.tap(find.text('Amazing Grace'));
    await tester.pumpAndSettle();
    expect(find.byType(SongView), findsOneWidget);
    expect(find.text('Start: repeat bars 5–8'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
