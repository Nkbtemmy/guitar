import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../audio/mic_listener.dart';
import '../theme.dart';

/// Mic state with a live level meter; explains what to do when access is denied.
class ListeningBadge extends StatelessWidget {
  const ListeningBadge({super.key, this.message});

  /// Feedback shown next to the meter, e.g. "Heard: A".
  final String? message;

  @override
  Widget build(BuildContext context) {
    final mic = context.watch<MicListener>();
    final (icon, text, color) = switch (mic.status) {
      MicStatus.listening => (Icons.mic_rounded, message ?? 'Listening…', kSuccess),
      MicStatus.starting || MicStatus.idle => (Icons.mic_none_rounded, 'Starting microphone…', kMuted),
      MicStatus.denied => (Icons.mic_off_rounded, 'Microphone access is off. Allow it in Settings, then tap retry.', kMiss),
      MicStatus.error => (Icons.error_outline_rounded, 'Microphone problem: ${mic.errorMessage ?? 'unknown'}', kMiss),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: kSurfaceHigh, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(color: color == kSuccess ? null : color, fontWeight: FontWeight.w600))),
        if (mic.status == MicStatus.listening) LevelMeter(level: mic.level),
        if (mic.status == MicStatus.denied || mic.status == MicStatus.error)
          TextButton(onPressed: mic.retry, child: const Text('Retry')),
      ]),
    );
  }
}

/// Five bars that light up with [level] (0..1).
class LevelMeter extends StatelessWidget {
  const LevelMeter({super.key, required this.level});

  final double level;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            margin: const EdgeInsets.only(left: 3),
            width: 5,
            height: 6.0 + i * 3.5,
            decoration: BoxDecoration(
              color: level * 5 > i + 0.3 ? kSuccess : kMuted.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    );
  }
}
