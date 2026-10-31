import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitaro/account/account_service.dart';
import 'package:guitaro/account/cloud_sync.dart';
import 'package:guitaro/progress/practice_log.dart';
import 'package:guitaro/sheets/songbook_store.dart';
import 'package:guitaro/app_services.dart';
import 'package:guitaro/curriculum/models.dart';
import 'package:guitaro/main.dart';
import 'package:guitaro/music/chord_library.dart';
import 'package:guitaro/practice/plan.dart';
import 'package:guitaro/progress/learning_goal.dart';
import 'package:guitaro/progress/progress_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show FakeMic, QuietPlayer;

/// Accounts with a pretend cloud: signing in always works (unless [refuse]), and the copy is a map.
class FakeAccounts extends AccountService {
  Account? _account;
  CloudCopy? cloud;
  bool refuse = false;
  int stores = 0;

  static const jean = Account(id: 'u1', name: 'Jean Uwase', email: 'jean@example.com', provider: 'google.com');

  @override
  bool get available => true;

  @override
  bool get appleAvailable => false;

  @override
  Account? get account => _account;

  @override
  Future<Account?> signInWithGoogle() async {
    if (refuse) throw Exception('offline');
    _account = jean;
    notifyListeners();
    return _account;
  }

  @override
  Future<Account?> signInWithApple() => signInWithGoogle();

  @override
  Future<void> signOut() async {
    _account = null;
    notifyListeners();
  }

  @override
  Future<void> deleteAccount() async {
    cloud = null;
    await signOut();
  }

  @override
  Future<CloudCopy?> fetch() async => _account == null ? null : cloud;

  @override
  Future<DateTime> store(Map<String, String> data) async {
    stores++;
    final at = DateTime.now();
    cloud = (data: {...data}, savedAt: at);
    return at;
  }
}

void main() {
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  AppServices services() => AppServices(
        library: ChordLibrary.fromJson(File('assets/data/chords.json').readAsStringSync(),
            tipsJson: File('assets/data/chord_tips.json').readAsStringSync()),
        curriculum: Curriculum.fromJson(File('assets/data/curriculum.json').readAsStringSync()),
        player: QuietPlayer(),
      );

  group('learning goal', () {
    test('is kept, and opens the course to someone who already plays', () {
      final store = ProgressStore(prefs);
      expect(store.goal, isNull);
      store.goal = const LearningGoal(experience: Experience.some, aims: {Aim.songs, Aim.blues}, minutes: 10);
      final again = ProgressStore(prefs);
      expect(again.goal!.aims, {Aim.songs, Aim.blues});
      expect(again.goal!.minutes, 10);
      expect(again.unlockAll, isTrue);
      expect(ProgressStore(prefs)..goal = const LearningGoal(), isA<ProgressStore>());
    });

    test('the daily plan fits the minutes set: the most needed parts first', () {
      final lesson = Curriculum.fromJson(File('assets/data/curriculum.json').readAsStringSync()).lessons.first;
      List<(PlanKind, int)> plan(int minutes) => [
            for (final i in dailyPlan(day: DateTime(2026, 10, 30), minutes: minutes, nextLesson: lesson)) (i.kind, i.minutes),
          ];
      expect(plan(5), [(PlanKind.tune, 1), (PlanKind.lesson, 4)]);
      expect(plan(10), [(PlanKind.tune, 1), (PlanKind.changes, 2), (PlanKind.metronome, 3), (PlanKind.lesson, 4)]);
      expect(plan(30).map((p) => p.$1), [PlanKind.tune, PlanKind.fretboard, PlanKind.changes, PlanKind.metronome, PlanKind.lesson, PlanKind.songs]);
      for (final m in LearningGoal.dailyMinutes) {
        expect(plan(m).fold(0, (sum, p) => sum + p.$2), m, reason: '$m minutes');
      }
    });
  });

  testWidgets('the first open asks for a goal, then goes home; the next open goes straight home', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final progress = ProgressStore(prefs);
    await tester.pumpWidget(GuitaroApp(services: services(), progress: progress, mic: FakeMic(), onboarding: true));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Guitaro'), findsOneWidget);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    // The goal page is longer than the screen: scroll to each answer before tapping it.
    Future<void> tap(String text) async {
      await tester.ensureVisible(find.text(text));
      await tester.pumpAndSettle();
      await tester.tap(find.text(text));
      await tester.pumpAndSettle();
    }

    await tap('I know a few chords');
    await tap('Blues');
    await tap('10 min');
    await tap('Remind me every day');
    await tap("Let's go");
    expect(progress.goal!.experience, Experience.some);
    expect(progress.goal!.aims, {Aim.songs, Aim.blues});
    expect(progress.goal!.minutes, 10);
    expect(progress.reminder, isNull, reason: 'no reminder asked for');
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text("Today's practice · 10 min"), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(GuitaroApp(services: services(), progress: ProgressStore(prefs), mic: FakeMic(), onboarding: true));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Guitaro'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('accounts', () {
    Future<void> pumpApp(WidgetTester tester, AccountService accounts, {bool onboarding = false}) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(GuitaroApp(
          services: services(), progress: ProgressStore(prefs), mic: FakeMic(), accounts: accounts, onboarding: onboarding));
      await tester.pumpAndSettle();
    }

    testWidgets('the welcome offers Google sign-in, or skipping it', (tester) async {
      final accounts = FakeAccounts();
      await pumpApp(tester, accounts, onboarding: true);
      expect(find.text('Get started'), findsNothing);
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      expect(accounts.account, FakeAccounts.jean);
      expect(find.text('Your goal'), findsOneWidget);
    });

    testWidgets('a failed sign-in says so and stays put; skipping goes on without an account', (tester) async {
      final accounts = FakeAccounts()..refuse = true;
      await pumpApp(tester, accounts, onboarding: true);
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't sign in. Check your connection and try again."), findsOneWidget);
      expect(find.text('Welcome to Guitaro'), findsOneWidget);
      await tester.tap(find.text('Skip for now'));
      await tester.pumpAndSettle();
      expect(find.text('Your goal'), findsOneWidget);
      expect(accounts.account, isNull);
    });

    testWidgets('Me: sign in to back up, then who is signed in, sign out, and delete the account', (tester) async {
      final accounts = FakeAccounts();
      await pumpApp(tester, accounts);
      await tester.tap(find.text('Me'));
      await tester.pumpAndSettle();
      expect(find.text('Back up your progress'), findsOneWidget);
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      expect(find.text('Jean Uwase'), findsOneWidget);
      expect(find.text('jean@example.com'), findsOneWidget);
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Back up your progress'), findsOneWidget);

      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      expect(find.text('Delete your account?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(accounts.account, isNull);
      expect(find.text('Your account is deleted.'), findsOneWidget);
    });

    testWidgets('a build without accounts shows none of it', (tester) async {
      await pumpApp(tester, NoAccounts());
      await tester.tap(find.text('Me'));
      await tester.pumpAndSettle();
      expect(find.text('Back up your progress'), findsNothing);
      expect(find.text('Continue with Google'), findsNothing);
    });
  });

  group('cloud sync', () {
    late FakeAccounts accounts;
    late ProgressStore progress;
    late PracticeLog practice;
    late SongbookStore songbook;
    late CloudSync sync;

    void phone() {
      progress = ProgressStore(prefs);
      practice = PracticeLog(prefs);
      songbook = SongbookStore(prefs);
      sync = CloudSync(
        accounts: accounts,
        prefs: prefs,
        stores: [
          (key: ProgressStore.storageKey, store: progress, reload: progress.reload),
          (key: PracticeLog.storageKey, store: practice, reload: practice.reload),
          (key: SongbookStore.storageKey, store: songbook, reload: songbook.reload),
        ],
        localIsEmpty: () => progress.lessonsCompleted == 0 && practice.isEmpty && songbook.userSongs.isEmpty,
        delay: Duration.zero,
      )..start();
    }

    /// Another phone, fresh: same account, nothing on it yet.
    Future<void> newPhone() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      phone();
    }

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

    setUp(() {
      accounts = FakeAccounts();
      phone();
    });

    test('the first phone fills the account; a new phone takes it, goal and all', () async {
      progress.completeLesson('L01-1', 3);
      progress.goal = const LearningGoal(aims: {Aim.blues}, minutes: 30);
      practice.recordChanges('C', 'G', 21);
      await accounts.signInWithGoogle();
      await sync.connect(useAccountCopy: () async => fail('nothing to choose between'));
      expect(accounts.cloud!.data.keys, {ProgressStore.storageKey, PracticeLog.storageKey, SongbookStore.storageKey});
      expect(sync.syncedAt, isNotNull);

      await newPhone();
      await sync.connect(useAccountCopy: () async => fail('a new phone has nothing to keep'));
      expect(progress.starsFor('L01-1'), 3);
      expect(progress.goal!.minutes, 30);
      expect(practice.bestChanges('G', 'C'), 21);
    });

    test('when both have progress, the learner chooses which to keep', () async {
      progress.completeLesson('L01-1', 1);
      await accounts.signInWithGoogle();
      accounts.cloud = (data: {ProgressStore.storageKey: '{"stars": {"L01-2": 3}, "xp": 50}'}, savedAt: DateTime(2026, 10, 1));
      var asked = 0;
      await sync.connect(useAccountCopy: () async {
        asked++;
        return true;
      });
      expect(asked, 1);
      expect(progress.isComplete('L01-2'), isTrue, reason: "the account's copy");
      expect(progress.isComplete('L01-1'), isFalse);

      progress.completeLesson('L01-3', 2);
      accounts.cloud = (data: {ProgressStore.storageKey: '{"stars": {"L09-1": 3}}'}, savedAt: DateTime(2026, 10, 2));
      await sync.connect(useAccountCopy: () async => false);
      expect(progress.isComplete('L01-3'), isTrue, reason: "this phone's");
      expect(accounts.cloud!.data[ProgressStore.storageKey], contains('L01-3'), reason: 'and it went up to the account');
    });

    test('a change goes up a moment later; nothing goes up while signed out', () async {
      await accounts.signInWithGoogle();
      await sync.connect(useAccountCopy: () async => true);
      final before = accounts.stores;
      practice.recordBest('ear:quality', 7);
      await settle();
      expect(accounts.stores, before + 1);
      expect(accounts.cloud!.data[PracticeLog.storageKey], contains('ear:quality'));

      await accounts.signOut();
      progress.leftHanded = true;
      await settle();
      expect(accounts.stores, before + 1, reason: 'signed out');
      await accounts.signInWithGoogle();
      await sync.resume();
      expect(accounts.cloud!.data[ProgressStore.storageKey], contains('"leftHanded":true'), reason: 'it goes up at the next sign-in');
    });

    test('at start, a newer copy from another phone comes down', () async {
      await accounts.signInWithGoogle();
      await sync.connect(useAccountCopy: () async => true);
      accounts.cloud = (
        data: {...accounts.cloud!.data, ProgressStore.storageKey: '{"stars": {"L02-1": 2}, "xp": 40}'},
        savedAt: DateTime.now().add(const Duration(minutes: 5)),
      );
      phone();
      await sync.resume();
      expect(progress.isComplete('L02-1'), isTrue);
      expect(progress.xp, 40);
    });
  });
}
