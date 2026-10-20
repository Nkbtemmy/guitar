import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../audio/analysis.dart';
import '../../audio/mic_listener.dart';

/// Holds the shared microphone while the widget is on screen and forwards frames to [onFrame].
mixin Listening<T extends StatefulWidget> on State<T> {
  late final MicListener mic = context.read<MicListener>();
  StreamSubscription<AnalysisFrame>? _frames;

  void onFrame(AnalysisFrame frame);

  @override
  void initState() {
    super.initState();
    _frames = mic.frames.listen((f) {
      if (mounted) onFrame(f);
    });
    mic.acquire();
  }

  @override
  void dispose() {
    _frames?.cancel();
    mic.release();
    super.dispose();
  }
}
