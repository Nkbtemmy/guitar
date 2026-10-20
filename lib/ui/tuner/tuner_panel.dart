import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../audio/analysis.dart';
import '../../music/notes.dart';
import '../theme.dart';
import '../widgets/listening.dart';
import '../widgets/listening_badge.dart';

/// Guitar tuner: picks the nearest open string automatically (or the one tapped), shows the
/// offset in cents, and ticks off each string after it stays in tune briefly.
class TunerPanel extends StatefulWidget {
  const TunerPanel({super.key, this.onAllTuned});

  final VoidCallback? onAllTuned;

  @override
  State<TunerPanel> createState() => _TunerPanelState();
}

class _TunerPanelState extends State<TunerPanel> with Listening {
  int? _selected;
  int? _string;
  double? _cents;
  double _needle = 0;
  String _note = '–';
  double? _inTuneSince;
  final _tuned = <int>{};

  @override
  void onFrame(AnalysisFrame f) {
    final p = f.pitch;
    if (p == null || p.clarity < 0.9) {
      _inTuneSince = null;
      if (!f.hasSound && _cents != null) setState(() => _cents = null);
      return;
    }
    final midi = p.midi;
    final string = _selected ??
        standardTuning.entries.reduce((a, b) => (midi - a.value).abs() < (midi - b.value).abs() ? a : b).key;
    final target = standardTuning[string]!;
    if (_selected == null && (midi - target).abs() > 5) return;
    final cents = (midi - target) * 100;
    setState(() {
      _string = string;
      _cents = cents;
      _note = noteName(midi.round());
      _needle = _needle * 0.5 + cents.clamp(-50.0, 50.0) * 0.5;
      if (cents.abs() <= 6) {
        _inTuneSince ??= f.time;
        if (f.time - _inTuneSince! > 0.6 && _tuned.add(string) && _tuned.length == 6) widget.onAllTuned?.call();
      } else {
        _inTuneSince = null;
      }
    });
  }

  void _select(int string) {
    setState(() => _selected = _selected == string ? null : string);
    if (_selected != null) context.read<AppServices>().player.playNote(standardTuning[string]!);
  }

  @override
  Widget build(BuildContext context) {
    final cents = _cents;
    final inTune = cents != null && cents.abs() <= 6;
    final color = cents == null ? kMuted : (inTune ? kSuccess : kAccent);
    final hint = cents == null
        ? 'Pluck one string'
        : inTune
            ? 'In tune!'
            : cents.abs() > 50
                ? (cents < 0 ? 'Much too low: tighten' : 'Much too high: loosen')
                : (cents < 0 ? 'A little low: tighten' : 'A little high: loosen');
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var s = 6; s >= 1; s--)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: _StringChip(
              label: stringLetters[s]!,
              selected: _selected == s,
              active: _string == s && cents != null,
              tuned: _tuned.contains(s),
              onTap: () => _select(s),
            ),
          ),
      ]),
      const SizedBox(height: 6),
      Text(_selected == null ? 'Auto-detecting string · tap a string to hear it' : 'Tuning string $_selected · tap again for auto',
          style: const TextStyle(color: kMuted, fontSize: 12)),
      const SizedBox(height: 18),
      Text(cents == null ? '–' : _note, style: TextStyle(fontSize: 72, fontWeight: FontWeight.w900, color: color, height: 1)),
      const SizedBox(height: 8),
      SizedBox(height: 120, width: double.infinity, child: CustomPaint(painter: _GaugePainter(cents == null ? null : _needle, color))),
      Text(cents == null ? hint : '$hint  (${cents >= 0 ? '+' : ''}${cents.round()} cents)',
          style: TextStyle(fontSize: 16, color: color, fontWeight: FontWeight.w700)),
      const SizedBox(height: 16),
      const ListeningBadge(),
    ]);
  }
}

class _StringChip extends StatelessWidget {
  const _StringChip({required this.label, required this.selected, required this.active, required this.tuned, required this.onTap});

  final String label;
  final bool selected, active, tuned;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final border = selected ? kAccent : (active ? kAccent.withValues(alpha: 0.5) : Colors.transparent);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: 46,
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tuned ? kSuccess.withValues(alpha: 0.2) : kSurfaceHigh,
          shape: BoxShape.circle,
          border: Border.all(color: border, width: 2),
        ),
        child: tuned
            ? const Icon(Icons.check_rounded, color: kSuccess)
            : Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter(this.cents, this.color);

  final double? cents;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.95);
    final radius = math.min(size.width * 0.42, size.height * 0.85);
    const sweep = math.pi * 0.7;
    final startAngle = -math.pi / 2 - sweep / 2;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..color = kSurfaceHigh;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), startAngle, sweep, false, arc);
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -math.pi / 2 - sweep * 0.06, sweep * 0.12, false,
        arc..color = kSuccess.withValues(alpha: 0.6));
    for (var c = -50; c <= 50; c += 10) {
      final a = -math.pi / 2 + c / 50 * sweep / 2;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(center + dir * (radius - 22), center + dir * (radius - (c % 50 == 0 ? 34 : 28)),
          Paint()
            ..color = kMuted
            ..strokeWidth = 2);
    }
    if (cents == null) return;
    final a = -math.pi / 2 + cents! / 50 * sweep / 2;
    canvas.drawLine(center, center + Offset(math.cos(a), math.sin(a)) * (radius - 8),
        Paint()
          ..color = color
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round);
    canvas.drawCircle(center, 8, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.cents != cents || old.color != color;
}
