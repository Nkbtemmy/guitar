import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_services.dart';
import '../progress/progress_store.dart';
import 'theme.dart';
import 'widgets/brand_mark.dart';

/// The opening screen: the logo on chocolate, picking up from the native launch screen, while
/// the six open strings ring out. Then it fades into [next].
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.next});

  final Widget next;

  static const duration = Duration(milliseconds: 1900);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    if (context.read<ProgressStore>().openingSound) {
      // Autoplay may be blocked (on the web, before any tap); the app opens either way.
      context.read<AppServices>().player.playOpenStrings().catchError((Object _) => Duration.zero);
    }
    _timer = Timer(SplashScreen.duration, _finish);
  }

  void _finish() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 450),
      pageBuilder: (_, _, _) => widget.next,
      transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
    ));
  }

  @override
  void dispose() {
    _timer.cancel();
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _intro, curve: Curves.easeOutBack);
    return Scaffold(
      backgroundColor: kAccent,
      body: Center(
        child: ScaleTransition(
          scale: Tween(begin: 0.85, end: 1.0).animate(curve),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const BrandMark.white(size: 120),
            const SizedBox(height: 20),
            FadeTransition(
              opacity: _intro,
              child: const Text(
                'Guitaro',
                style: TextStyle(color: kOnAccent, fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 0.5),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
