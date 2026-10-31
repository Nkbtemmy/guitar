import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:guitaro/audio/mic_listener.dart';
import 'package:guitaro/sheets/songbook_store.dart';
import 'package:guitaro/app_services.dart';
import 'package:guitaro/curriculum/models.dart';
import 'package:guitaro/main.dart';
import 'package:guitaro/music/chord_library.dart';
import 'package:guitaro/practice/plan.dart';
import 'package:guitaro/practice/report.dart';
import 'package:guitaro/ui/practice/homework_screen.dart';
import 'package:guitaro/ui/practice/report_screen.dart';
import 'package:guitaro/practice/reminders.dart';
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

  test('practice minutes add up by day, and plan items tick off for the day', () {
    final log = PracticeLog(prefs);
    final mon = DateTime(2026, 10, 26, 9), tue = DateTime(2026, 10, 27, 20);
    log.addPractice(const Duration(minutes: 10), now: mon);
    log.addPractice(const Duration(minutes: 5), now: mon);
    log.addPractice(const Duration(hours: 9), now: tue);
    log.markDone('tune', now: tue);
    final again = PracticeLog(prefs);
    expect(again.practicedOn(mon), const Duration(minutes: 15));
    expect(again.practicedOn(tue), const Duration(hours: 6), reason: 'a phone left listening is not nine hours of practice');
    expect(again.practicedOver(7, now: tue), const Duration(hours: 6, minutes: 15));
    expect(again.isDone('tune', now: tue), isTrue);
    expect(again.isDone('tune', now: mon), isFalse);
  });

  test("today's plan: tune, warm up (alternating), changes, the weak spot, the next lesson", () {
    final lesson = Curriculum.fromJson(File('assets/data/curriculum.json').readAsStringSync()).lessons.first;
    final spot = WeakSpot(place: grace, from: 4, to: 8, title: 'Amazing Grace', detail: 'Bars 5–8', misses: 3);
    final plan = dailyPlan(day: DateTime(2026, 10, 30), nextLesson: lesson, pair: ('A', 'D'), spot: spot);
    expect([for (final i in plan) i.kind],
        [PlanKind.tune, PlanKind.fretboard, PlanKind.changes, PlanKind.spot, PlanKind.lesson]);
    expect(plan[2].title, 'Chord changes: A – D');
    expect(plan.fold(0, (sum, i) => sum + i.minutes), 15);
    final light = dailyPlan(day: DateTime(2026, 10, 31));
    expect([for (final i in light) i.kind], [PlanKind.tune, PlanKind.ear, PlanKind.changes, PlanKind.metronome, PlanKind.songs]);
    expect(light[2].pair, ('C', 'G'));
  });

  test('the reminder fires next at its time today, or tomorrow once it has passed', () {
    final morning = DateTime(2026, 10, 31, 9);
    // The same instants, given in UTC.
    DateTime local(DateTime t) => DateTime.fromMillisecondsSinceEpoch(t.millisecondsSinceEpoch);
    expect(local(Reminders.nextAt(18 * 60 + 30, morning)), DateTime(2026, 10, 31, 18, 30));
    expect(local(Reminders.nextAt(8 * 60, morning)), DateTime(2026, 11, 1, 8));
    expect(Reminders.nextAt(8 * 60, morning).location.name, 'Etc/UTC');
  });

  testWidgets("today's practice shows what's next, the whole plan on a tap, and opens each part", (tester) async {
    final services = AppServices(
      library: ChordLibrary.fromJson(File('assets/data/chords.json').readAsStringSync(),
          tipsJson: File('assets/data/chord_tips.json').readAsStringSync()),
      curriculum: Curriculum.fromJson(File('assets/data/curriculum.json').readAsStringSync()),
      player: QuietPlayer(),
    );
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final log = PracticeLog(prefs)..markDone('tune');
    await tester.pumpWidget(GuitaroApp(services: services, progress: ProgressStore(prefs), mic: FakeMic(), practice: log));
    await tester.pumpAndSettle();
    expect(find.text("Today's practice · 15 min"), findsOneWidget);
    expect(find.text('1/5'), findsOneWidget);
    expect(find.text('Tune up'), findsNothing, reason: 'done: what shows is the next part');
    await tester.tap(find.text('Whole plan (5)'));
    await tester.pumpAndSettle();
    expect(find.text('Tune up'), findsOneWidget);
    await tester.tap(find.text('Chord changes: C – G'));
    await tester.pumpAndSettle();
    expect(find.text('Start: 60 seconds'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('homework ticks itself off for a whole run fast enough and right enough, and keeps', () {
    final log = PracticeLog(prefs);
    final grace = Homework(id: 'a', place: const SpotPlace.sheet('pd:amazing_grace'), title: 'Amazing Grace', tempo: 0.8, due: DateTime(2026, 11, 7));
    final ode = Homework(id: 'b', place: const SpotPlace.tab('pd:ode_to_joy', 0), title: 'Ode to Joy · Melody', due: DateTime(2026, 11, 3));
    log
      ..addHomework(grace)
      ..addHomework(ode);
    expect([for (final h in log.homework) h.id], ['b', 'a'], reason: 'soonest due first');
    expect(log.completeHomework(const SpotPlace.sheet('pd:amazing_grace'), tempo: 0.7, accuracy: 1), isEmpty, reason: 'too slow');
    expect(log.completeHomework(const SpotPlace.sheet('pd:amazing_grace'), tempo: 0.8, accuracy: 0.7), isEmpty, reason: 'too many missed');
    expect(log.completeHomework(const SpotPlace.sheet('pd:amazing_grace'), tempo: 0.85, accuracy: 0.9), [grace]);
    final again = PracticeLog(prefs);
    expect([for (final h in again.homework) (h.id, h.done)], [('b', false), ('a', true)], reason: 'what is still to do first');
  });

  test("the report: course, practice, chord changes, best scores, homework and what's next", () {
    final curriculum = Curriculum.fromJson(File('assets/data/curriculum.json').readAsStringSync());
    final progress = ProgressStore(prefs)..completeLesson(curriculum.lessons.first.id, 3, now: DateTime(2026, 10, 31));
    final log = PracticeLog(prefs)
      ..addPractice(const Duration(minutes: 40), now: DateTime(2026, 10, 30))
      ..recordChanges('C', 'G', 14, now: DateTime(2026, 10, 1))
      ..recordChanges('C', 'G', 31, now: DateTime(2026, 10, 30))
      ..recordBest('ear:quality', 9)
      ..addHomework(Homework(id: 'a', place: const SpotPlace.sheet('x'), title: 'Amazing Grace', tempo: 0.8, due: DateTime(2026, 11, 7)));
    miss(log, 4, now: DateTime(2026, 10, 30));
    final report = progressReport(name: 'Jean', progress: progress, log: log, curriculum: curriculum, now: DateTime(2026, 10, 31, 18));
    expect(report, startsWith('Guitaro progress · Jean · 31 Oct 2026'));
    expect(report, contains('Course: 1 of ${curriculum.lessons.length} lessons, 3 stars'));
    expect(report, contains('Practice: 40 min in the last 7 days'));
    expect(report, contains('C – G best 31/min (first 14)'));
    expect(report, contains('Major or minor 9/10'));
    expect(report, contains('○ Amazing Grace at 80% speed by 7 Nov'));
    expect(report, contains('Amazing Grace, bars 5–8 (missed 1 of 1)'));
  });

  test('homework set is part of the day', () {
    final h = Homework(id: 'a', place: const SpotPlace.sheet('x'), title: 'Amazing Grace', tempo: 0.8);
    final plan = dailyPlan(day: DateTime(2026, 10, 31), homework: h);
    expect(plan[4].title, 'Homework: Amazing Grace');
    expect(plan[4].detail, 'Play it through at 80% speed');
  });

  testWidgets('a teacher sets homework, and the report is ready to send', (tester) async {
    final services = AppServices(
      library: ChordLibrary.fromJson(File('assets/data/chords.json').readAsStringSync(),
          tipsJson: File('assets/data/chord_tips.json').readAsStringSync()),
      curriculum: Curriculum.fromJson(File('assets/data/curriculum.json').readAsStringSync()),
      player: QuietPlayer(),
    );
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final log = PracticeLog(prefs);
    final progress = ProgressStore(prefs);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider.value(value: services),
        ChangeNotifierProvider.value(value: progress),
        ChangeNotifierProvider.value(value: log),
        ChangeNotifierProvider.value(value: SongbookStore(prefs)),
        ChangeNotifierProvider<MicListener>.value(value: FakeMic()),
      ],
      child: const MaterialApp(home: HomeworkScreen()),
    ));
    await tester.tap(find.text('Set homework'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Down in the');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Down in the Valley (lesson)').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Note (optional)'), 'Watch the change to D7');
    await tester.tap(find.text('Set it'));
    await tester.pumpAndSettle();
    expect(find.text('Down in the Valley (lesson)'), findsOneWidget);
    expect(find.text('At 80% speed · Watch the change to D7'), findsOneWidget);
    expect(log.homework.single.place, const SpotPlace.song('down_in_the_valley'));

    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider.value(value: services),
        ChangeNotifierProvider.value(value: progress),
        ChangeNotifierProvider.value(value: log),
      ],
      child: const MaterialApp(home: ReportScreen()),
    ));
    await tester.enterText(find.byType(TextField), 'Jean');
    await tester.pumpAndSettle();
    expect(find.textContaining('Guitaro progress · Jean'), findsOneWidget);
    expect(find.textContaining('○ Down in the Valley (lesson) at 80% speed'), findsOneWidget);
    expect(progress.studentName, 'Jean');
    expect(tester.takeException(), isNull);
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
