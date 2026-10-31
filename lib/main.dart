import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'dart:async';

import 'account/account_service.dart';
import 'account/cloud_sync.dart';
import 'account/firebase_accounts.dart';
import 'analytics.dart';
import 'app_services.dart';
import 'firebase_setup.dart';
import 'audio/mic_listener.dart';
import 'audio/sound_player.dart';
import 'practice/reminders.dart';
import 'progress/practice_log.dart';
import 'progress/progress_store.dart';
import 'sheets/songbook_store.dart';
import 'ui/chords/chords_screen.dart';
import 'ui/learn/learn_screen.dart';
import 'ui/onboarding/onboarding_screen.dart';
import 'ui/profile/profile_screen.dart';
import 'ui/songs/songs_screen.dart';
import 'ui/splash_screen.dart';
import 'ui/theme.dart';
import 'ui/tuner/tuner_panel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Dark status-bar icons over the white UI.
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent));
  final prefs = await SharedPreferences.getInstance();
  final progress = ProgressStore(prefs);
  final mic = MicListener(sensitivity: progress.sensitivity);
  progress.addListener(() => mic.sensitivity = progress.sensitivity);
  // Both hands are on the guitar, so the screen mustn't go dark mid-song (Me › Keep the screen on).
  // The system lets it sleep again as soon as the app is in the background.
  bool? awake;
  void keepAwake() {
    if (awake == progress.keepScreenOn) return;
    awake = progress.keepScreenOn;
    WakelockPlus.toggle(enable: progress.keepScreenOn).catchError((Object e) => debugPrint('Keeping the screen on failed: $e'));
  }

  keepAwake();
  progress.addListener(keepAwake);
  final practice = PracticeLog(prefs);
  // The daily reminder, set again at every start (see Reminders.nextAt) and whenever it changes.
  final reminders = Reminders();
  int? remindAt;
  void remind() {
    if (remindAt == progress.reminder) return;
    remindAt = progress.reminder;
    reminders.set(remindAt);
  }

  reminders.set(progress.reminder);
  remindAt = progress.reminder;
  progress.addListener(remind);
  // Practice time: while the mic listens, the learner is playing.
  DateTime? listeningSince;
  mic.addListener(() {
    final listening = mic.status == MicStatus.listening;
    if (listening) {
      listeningSince ??= DateTime.now();
    } else if (listeningSince case final since?) {
      practice.addPractice(DateTime.now().difference(since));
      listeningSince = null;
    }
  });
  try {
    await SoundPlayer.configureAudioSession();
  } catch (e) {
    debugPrint('Audio session setup failed: $e');
  }
  final player = SoundPlayer(onReferenceSound: (d) => mic.suppress(d + const Duration(milliseconds: 300)));
  final (services, firebase) = await (AppServices.load(rootBundle, player), startFirebase()).wait;
  final analytics = Analytics.start(firebase: firebase, enabled: progress.shareUsage);
  final accounts = firebase ? FirebaseAccounts() : NoAccounts();
  final songbook = SongbookStore(prefs);
  // Progress, practice and songs follow the learner's account (when they've signed in).
  final sync = CloudSync(
    accounts: accounts,
    prefs: prefs,
    stores: [
      (key: ProgressStore.storageKey, store: progress, reload: progress.reload),
      (key: PracticeLog.storageKey, store: practice, reload: practice.reload),
      (key: SongbookStore.storageKey, store: songbook, reload: songbook.reload),
    ],
    localIsEmpty: () =>
        progress.lessonsCompleted == 0 && practice.isEmpty && songbook.userSongs.isEmpty && songbook.setlists.isEmpty,
  )..start();
  if (accounts.account != null) unawaited(sync.resume());
  progress.addListener(() => analytics.enabled = progress.shareUsage);
  runApp(GuitaroApp(
    services: services,
    progress: progress,
    mic: mic,
    songbook: songbook,
    practice: practice,
    reminders: reminders,
    accounts: accounts,
    sync: sync,
    analytics: analytics,
    splash: true,
    onboarding: true,
  ));
}

class GuitaroApp extends StatelessWidget {
  GuitaroApp({
    super.key,
    required this.services,
    required this.progress,
    required this.mic,
    SongbookStore? songbook,
    PracticeLog? practice,
    Reminders? reminders,
    AccountService? accounts,
    this.sync,
    Analytics? analytics,
    this.splash = false,
    this.onboarding = false,
  })  : songbook = songbook ?? SongbookStore(),
        practice = practice ?? PracticeLog(),
        reminders = reminders ?? Reminders(),
        accounts = accounts ?? NoAccounts(),
        analytics = analytics ?? const Analytics();

  final AppServices services;
  final ProgressStore progress;
  final MicListener mic;

  /// Favorites, setlists and the learner's own songs.
  final SongbookStore songbook;

  /// What the learner has practised: weak spots and more.
  final PracticeLog practice;

  /// The daily practice reminder.
  final Reminders reminders;

  /// Signing in, and the learner's cloud copy.
  final AccountService accounts;

  /// Keeps the learner's data in their account; none in a build without accounts, or a test.
  final CloudSync? sync;

  /// Anonymous usage stats; sends nothing unless Firebase started.
  final Analytics analytics;

  /// Open on the splash screen (with its opening strum) before the home screen.
  final bool splash;

  /// Ask a learner who hasn't set a goal yet for one, before the home screen.
  final bool onboarding;

  @override
  Widget build(BuildContext context) => MultiProvider(
        providers: [
          Provider.value(value: services),
          ChangeNotifierProvider.value(value: progress),
          ChangeNotifierProvider.value(value: mic),
          ChangeNotifierProvider.value(value: songbook),
          ChangeNotifierProvider.value(value: practice),
          Provider.value(value: reminders),
          ChangeNotifierProvider.value(value: accounts),
          Provider<CloudSync?>.value(value: sync),
          Provider.value(value: analytics),
        ],
        child: MaterialApp(
          title: 'Guitaro',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          home: Builder(builder: (context) {
            final first = onboarding && progress.goal == null ? const OnboardingScreen(next: HomeShell()) : const HomeShell();
            return splash ? SplashScreen(next: first) : first;
          }),
        ),
      );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  static const _destinations = [
    NavigationDestination(icon: Icon(Icons.school_outlined), selectedIcon: Icon(Icons.school_rounded), label: 'Learn'),
    NavigationDestination(icon: Icon(Icons.queue_music_outlined), selectedIcon: Icon(Icons.queue_music_rounded), label: 'Songs'),
    NavigationDestination(icon: Icon(Icons.grid_view_outlined), selectedIcon: Icon(Icons.grid_view_rounded), label: 'Chords'),
    NavigationDestination(icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune_rounded), label: 'Tuner'),
    NavigationDestination(icon: Icon(Icons.person_outline_rounded), selectedIcon: Icon(Icons.person_rounded), label: 'Me'),
  ];

  @override
  void initState() {
    super.initState();
    context.read<Analytics>().tab(_destinations[_tab].label);
  }

  void _select(int i) {
    if (i == _tab) return;
    setState(() => _tab = i);
    context.read<Analytics>().tab(_destinations[i].label);
  }

  @override
  Widget build(BuildContext context) {
    final body = switch (_tab) {
      0 => const LearnScreen(),
      1 => const SongsScreen(),
      2 => const ChordsScreen(),
      // The tuner only holds the mic while its tab is visible.
      3 => ListView(padding: const EdgeInsets.all(20), children: const [
          Text('Tuner', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
          SizedBox(height: 20),
          TunerPanel(),
        ]),
      _ => const ProfileScreen(),
    };
    return Scaffold(
      body: SafeArea(child: body),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _select,
        destinations: _destinations,
      ),
    );
  }
}
