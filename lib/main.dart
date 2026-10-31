import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'analytics.dart';
import 'app_services.dart';
import 'audio/mic_listener.dart';
import 'audio/sound_player.dart';
import 'progress/progress_store.dart';
import 'sheets/songbook_store.dart';
import 'ui/chords/chords_screen.dart';
import 'ui/learn/learn_screen.dart';
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
  try {
    await SoundPlayer.configureAudioSession();
  } catch (e) {
    debugPrint('Audio session setup failed: $e');
  }
  final player = SoundPlayer(onReferenceSound: (d) => mic.suppress(d + const Duration(milliseconds: 300)));
  final (services, analytics) =
      await (AppServices.load(rootBundle, player), Analytics.start(enabled: progress.shareUsage)).wait;
  progress.addListener(() => analytics.enabled = progress.shareUsage);
  runApp(GuitaroApp(
      services: services, progress: progress, mic: mic, songbook: SongbookStore(prefs), analytics: analytics, splash: true));
}

class GuitaroApp extends StatelessWidget {
  GuitaroApp({
    super.key,
    required this.services,
    required this.progress,
    required this.mic,
    SongbookStore? songbook,
    Analytics? analytics,
    this.splash = false,
  })  : songbook = songbook ?? SongbookStore(),
        analytics = analytics ?? const Analytics();

  final AppServices services;
  final ProgressStore progress;
  final MicListener mic;

  /// Favorites, setlists and the learner's own songs.
  final SongbookStore songbook;

  /// Anonymous usage stats; sends nothing unless Firebase started.
  final Analytics analytics;

  /// Open on the splash screen (with its opening strum) before the home screen.
  final bool splash;

  @override
  Widget build(BuildContext context) => MultiProvider(
        providers: [
          Provider.value(value: services),
          ChangeNotifierProvider.value(value: progress),
          ChangeNotifierProvider.value(value: mic),
          ChangeNotifierProvider.value(value: songbook),
          Provider.value(value: analytics),
        ],
        child: MaterialApp(
          title: 'Guitaro',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          home: splash ? const SplashScreen(next: HomeShell()) : const HomeShell(),
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
