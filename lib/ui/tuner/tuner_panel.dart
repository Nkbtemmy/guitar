import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../audio/analysis.dart';
import '../../music/notes.dart';
import '../theme.dart';
import '../widgets/listening.dart';
import '../widgets/listening_badge.dart';

/// Guitar tuner: a headstock with a peg for each string. With Auto on it works out which string
/// is ringing; with Auto off, tap a peg to tune that string (and hear it). A straight meter shows
/// how many cents off it is, and each peg is ticked off once its string stays in tune briefly.
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

  /// Tuning one string: Auto goes off, and the string's note plays so the learner can hear it.
  void _select(int string) {
    setState(() => _selected = string);
    context.read<AppServices>().player.playNote(standardTuning[string]!);
  }

  void _setAuto(bool auto) => setState(() => _selected = auto ? null : (_string ?? 6));

  @override
  Widget build(BuildContext context) {
    final cents = _cents;
    final inTune = cents != null && cents.abs() <= 6;
    final color = cents == null ? kMuted : (inTune ? kSuccess : kAccent);
    final hint = cents == null
        ? (_selected == null ? 'Pluck any string' : 'Pluck the ${stringLetters[_selected]} string')
        : inTune
            ? 'In tune!'
            : cents.abs() > 50
                ? (cents < 0 ? 'Much too low: tighten' : 'Much too high: loosen')
                : (cents < 0 ? 'A little low: tighten' : 'A little high: loosen');
    return Column(children: [
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Guitar · Standard', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            Text([for (var s = 6; s >= 1; s--) stringLetters[s]!.toUpperCase()].join(' '), style: const TextStyle(color: kMuted)),
          ]),
        ),
        const Text('AUTO', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2, fontSize: 13)),
        const SizedBox(width: 6),
        Switch(value: _selected == null, onChanged: _setAuto),
      ]),
      const SizedBox(height: 12),
      SizedBox(
        height: 92,
        width: double.infinity,
        child: CustomPaint(painter: _CentsMeterPainter(cents == null ? null : _needle, color)),
      ),
      const SizedBox(height: 6),
      AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(color: cents == null ? kSurfaceHigh : color, borderRadius: BorderRadius.circular(20)),
        child: Text(
          cents == null ? '– – –' : '$_note  ${cents >= 0 ? '+' : ''}${cents.round()}',
          style: TextStyle(fontWeight: FontWeight.w800, color: cents == null ? kMuted : kOnAccent),
        ),
      ),
      const SizedBox(height: 8),
      Text(hint, style: TextStyle(fontSize: 16, color: color, fontWeight: FontWeight.w700)),
      const SizedBox(height: 14),
      _Headstock(
        selected: _selected,
        active: cents == null ? null : _string,
        inTune: inTune,
        tuned: _tuned,
        onTap: _select,
      ),
      const SizedBox(height: 12),
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: () => _howToTune(context),
            icon: const Icon(Icons.play_arrow_outlined),
            label: const Text('How to tune?'),
          ),
          Text('${_tuned.length} of 6 in tune', style: const TextStyle(color: kMuted)),
        ],
      ),
      const SizedBox(height: 12),
      const ListeningBadge(),
    ]);
  }

  void _howToTune(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        // Scrolls with large text instead of running off the bottom.
        isScrollControlled: true,
        builder: (_) => const SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('How to tune', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              SizedBox(height: 12),
              _Tip(n: 1, text: 'Pluck one string and let it ring. With Auto on, Guitaro works out which string it is.'),
              _Tip(n: 2, text: 'Left of the middle is too low; right is too high.'),
              _Tip(n: 3, text: 'Too low: turn its peg to tighten the string. Too high: loosen it. Small turns, then pluck again.'),
              _Tip(n: 4, text: 'When the marker sits in the middle and turns green, that string is in tune. Its peg gets a tick.'),
              SizedBox(height: 8),
              Text(
                'Tip: tune up to the note. If you go past it, drop below and come back up: the string holds its tuning better. '
                'To tune one string on purpose, turn Auto off and tap its peg to hear how it should sound.',
                style: TextStyle(color: kMuted, height: 1.4),
              ),
            ]),
          ),
        ),
      );
}

class _Tip extends StatelessWidget {
  const _Tip({required this.n, required this.text});

  final int n;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(radius: 12, backgroundColor: kAccent, child: Text('$n', style: const TextStyle(color: kOnAccent, fontSize: 13, fontWeight: FontWeight.w800))),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 15, height: 1.35))),
        ]),
      );
}

/// Ticks from -50 to +50 cents across the width, the in-tune zone in the middle, and a marker
/// at [cents] (none while nothing is heard).
class _CentsMeterPainter extends CustomPainter {
  _CentsMeterPainter(this.cents, this.color);

  final double? cents;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const margin = 10.0;
    final width = size.width - 2 * margin;
    double x(double c) => margin + (c + 50) / 100 * width;
    final mid = size.height / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x(0), mid), width: width * 0.12, height: size.height * 0.62), const Radius.circular(10)),
      Paint()..color = kSuccess.withValues(alpha: 0.12),
    );
    for (var c = -50; c <= 50; c += 5) {
      final long = c == 0 || c.abs() == 50;
      final h = size.height * (long ? 0.86 : 0.36);
      canvas.drawLine(
        Offset(x(c.toDouble()), mid - h / 2),
        Offset(x(c.toDouble()), mid + h / 2),
        Paint()
          ..color = c == 0 ? kText : kMuted.withValues(alpha: long ? 0.9 : 0.6)
          ..strokeWidth = c == 0 ? 3 : 2
          ..strokeCap = StrokeCap.round,
      );
    }
    final at = cents;
    if (at == null) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x(at), mid), width: 22, height: size.height * 0.62), const Radius.circular(8)),
      Paint()..color = color.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(_CentsMeterPainter old) => old.cents != cents || old.color != color;
}

/// A three-a-side headstock seen from the front: D A E pegs down the left, G B e down the right,
/// each string running from its post down to the nut. The string being tuned lights up.
class _Headstock extends StatelessWidget {
  const _Headstock({required this.selected, required this.active, required this.inTune, required this.tuned, required this.onTap});

  final int? selected, active;
  final bool inTune;
  final Set<int> tuned;
  final ValueChanged<int> onTap;

  /// Pegs top to bottom on each side: (string, left side).
  static const pegs = [(4, true), (5, true), (6, true), (3, false), (2, false), (1, false)];

  static const background = Color(0xFF2A1C14), line = Color(0xFFEDE3D3), glow = Color(0xFFF0B27A), tick = Color(0xFF6FD49A);

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(20)),
        child: AspectRatio(
          aspectRatio: 0.95,
          child: LayoutBuilder(builder: (context, c) {
            final size = c.biggest;
            final row = [0.25, 0.47, 0.69];
            return Stack(children: [
              Positioned.fill(child: CustomPaint(painter: _HeadstockPainter(lit: active ?? selected, inTune: inTune && active != null))),
              for (var i = 0; i < 6; i++)
                Positioned(
                  left: pegs[i].$2 ? size.width * 0.04 : null,
                  right: pegs[i].$2 ? null : size.width * 0.04,
                  top: size.height * row[i % 3] - 28,
                  child: _Peg(
                    string: pegs[i].$1,
                    selected: selected == pegs[i].$1,
                    active: active == pegs[i].$1,
                    tuned: tuned.contains(pegs[i].$1),
                    onTap: () => onTap(pegs[i].$1),
                  ),
                ),
            ]);
          }),
        ),
      );
}

class _Peg extends StatelessWidget {
  const _Peg({required this.string, required this.selected, required this.active, required this.tuned, required this.onTap});

  final int string;
  final bool selected, active, tuned;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fill = selected ? _Headstock.glow : _Headstock.background;
    final edge = tuned ? _Headstock.tick : (selected || active ? _Headstock.glow : _Headstock.line);
    final ink = selected ? _Headstock.background : (tuned ? _Headstock.tick : _Headstock.line);
    return Semantics(
      button: true,
      label: 'Tune string $string, ${stringLetters[string]}${tuned ? ', in tune' : ''}',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 64,
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: edge, width: active || selected ? 3.5 : 2.5),
            boxShadow: [if (active) BoxShadow(color: _Headstock.glow.withValues(alpha: 0.5), blurRadius: 14)],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(stringLetters[string]!.toUpperCase(), style: TextStyle(color: ink, fontSize: 26, fontWeight: FontWeight.w900)),
            if (tuned) Icon(Icons.check_rounded, size: 16, color: ink),
          ]),
        ),
      ),
    );
  }
}

class _HeadstockPainter extends CustomPainter {
  _HeadstockPainter({required this.lit, required this.inTune});

  /// The string to light up, if any.
  final int? lit;
  final bool inTune;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = _Headstock.line.withValues(alpha: 0.9);
    // The headstock: a crowned top, sides that flare out, then narrow into the neck.
    final body = Path()
      ..moveTo(w * 0.31, h * 0.13)
      ..quadraticBezierTo(w * 0.42, h * 0.11, w * 0.5, h * 0.05)
      ..quadraticBezierTo(w * 0.58, h * 0.11, w * 0.69, h * 0.13)
      ..lineTo(w * 0.7, h * 0.78)
      ..quadraticBezierTo(w * 0.62, h * 0.86, w * 0.61, h * 0.9)
      ..lineTo(w * 0.61, h)
      ..moveTo(w * 0.31, h * 0.13)
      ..lineTo(w * 0.3, h * 0.78)
      ..quadraticBezierTo(w * 0.38, h * 0.86, w * 0.39, h * 0.9)
      ..lineTo(w * 0.39, h);
    canvas.drawPath(body, outline);
    // Nut, and the strings fanning up from it to their posts.
    final nutY = h * 0.9;
    canvas.drawRect(Rect.fromLTRB(w * 0.385, nutY - h * 0.012, w * 0.615, nutY + h * 0.012), outline);
    final posts = {4: (0.4, 0.25), 5: (0.4, 0.47), 6: (0.4, 0.69), 3: (0.6, 0.25), 2: (0.6, 0.47), 1: (0.6, 0.69)};
    for (final MapEntry(key: string, value: (px, py)) in posts.entries) {
      final post = Offset(w * px, h * py);
      // Pegs sit outside the headstock, joined to their posts by the shaft.
      final left = px < 0.5;
      canvas.drawLine(Offset(left ? w * 0.18 : w * 0.82, post.dy), Offset(left ? w * 0.31 : w * 0.69, post.dy), outline);
      canvas.drawCircle(post, w * 0.045, outline..color = _Headstock.line.withValues(alpha: 0.35));
      canvas.drawCircle(post, w * 0.022, outline);
      outline.color = _Headstock.line.withValues(alpha: 0.9);
      // Low E leaves the nut on the left, high e on the right.
      final atNut = Offset(w * (0.405 + (6 - string) * 0.038), nutY);
      final on = string == lit;
      canvas.drawLine(
        atNut,
        post + Offset(left ? w * 0.02 : -w * 0.02, 0),
        Paint()
          ..strokeWidth = on ? 3 : 1.2 + (string - 1) * 0.25
          ..color = on ? (inTune ? _Headstock.tick : _Headstock.glow) : _Headstock.line.withValues(alpha: 0.4),
      );
      canvas.drawLine(atNut, Offset(atNut.dx, h), Paint()
        ..strokeWidth = on ? 3 : 1.2 + (string - 1) * 0.25
        ..color = on ? (inTune ? _Headstock.tick : _Headstock.glow) : _Headstock.line.withValues(alpha: 0.4));
    }
  }

  @override
  bool shouldRepaint(_HeadstockPainter old) => old.lit != lit || old.inTune != inTune;
}
