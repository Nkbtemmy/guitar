import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitaro/account/account_service.dart';
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
  Future<void> store(Map<String, String> data) async {
    stores++;
    cloud = (data: {...data}, savedAt: DateTime.now());
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
}
