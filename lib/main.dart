import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_services.dart';
import 'audio/mic_listener.dart';
import 'audio/sound_player.dart';
import 'progress/progress_store.dart';
import 'ui/chords/chords_screen.dart';
import 'ui/learn/learn_screen.dart';
import 'ui/profile/profile_screen.dart';
import 'ui/songs/songs_screen.dart';
import 'ui/theme.dart';
import 'ui/tuner/tuner_panel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Dark status-bar icons over the white UI.
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent));
  final progress = ProgressStore(await SharedPreferences.getInstance());
  final mic = MicListener(sensitivity: progress.sensitivity);
  progress.addListener(() => mic.sensitivity = progress.sensitivity);
  try {
    await SoundPlayer.configureAudioSession();
  } catch (e) {
    debugPrint('Audio session setup failed: $e');
  }
  final player = SoundPlayer(onReferenceSound: (d) => mic.suppress(d + const Duration(milliseconds: 300)));
  final services = await AppServices.load(rootBundle, player);
  runApp(FretwiseApp(services: services, progress: progress, mic: mic));
}

class FretwiseApp extends StatelessWidget {
  const FretwiseApp({super.key, required this.services, required this.progress, required this.mic});

  final AppServices services;
  final ProgressStore progress;
  final MicListener mic;

  @override
  Widget build(BuildContext context) => MultiProvider(
        providers: [
          Provider.value(value: services),
          ChangeNotifierProvider.value(value: progress),
          ChangeNotifierProvider.value(value: mic),
        ],
        child: MaterialApp(
          title: 'Fretwise',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          home: const HomeShell(),
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
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: _destinations,
      ),
    );
  }
}
