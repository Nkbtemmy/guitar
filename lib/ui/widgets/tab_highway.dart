import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../progress/progress_store.dart';
import '../theme.dart';

/// A chord or note on the [TabHighway], [beat] beats from the start.
class HighwayNote {
  const HighwayNote(this.beat, this.frets, {this.muted = const {}, this.label});

  final double beat;

  /// String number (1 = high e .. 6 = low E) to fret.
  final Map<int, int> frets;
  final Set<int> muted;

  /// A chord name shown in a bubble above the note.
  final String? label;
}

/// A strum on the [TabHighway]: an arrow under the strings, down or up.
class HighwayStrum {
  const HighwayStrum(this.beat, {required this.down, this.muted = false, this.accent = false});

  final double beat;
  final bool down, muted, accent;
}

/// Tab that scrolls past a fixed play line. Notes sit on their strings as fret numbers on white
/// tiles, chord names ride above in bubbles, strums show as arrows underneath, and the play line
/// glows where the music is now: [position], in beats. Once judged, a note's tiles turn green
/// (played right) or red (missed). Strings follow Me › String order.
class TabHighway extends StatelessWidget {
  const TabHighway({
    super.key,
    required this.notes,
    required this.position,
    this.bars = const [],
    this.strums = const [],
    this.results = const [],
    this.height = 190,
    this.beatWidth = 64,
  });

  /// In order of [HighwayNote.beat].
  final List<HighwayNote> notes;
  final ValueListenable<double> position;

  /// Beats where bars start.
  final List<double> bars;
  final List<HighwayStrum> strums;

  /// How each note went, by index: right, missed, or null (not judged). May be shorter than [notes].
  final List<bool?> results;
  final double height, beatWidth;

  /// Where the play line sits, as a share of the width: far enough in that the notes just
  /// played (green or red) stay in view.
  static const playLine = 0.32;

  @override
  Widget build(BuildContext context) {
    final order = context.select<ProgressStore, StringOrder>((p) => p.stringOrder);
    final lanes = _Lanes(strums: strums.isNotEmpty);
    return SizedBox(
      height: height,
      child: Stack(fit: StackFit.expand, children: [
        // The strip and its strings never move: drawn once, apart from the notes repainting.
        RepaintBoundary(child: CustomPaint(painter: _StripPainter(order: order, lanes: lanes))),
        CustomPaint(
          painter: _NotesPainter(
            notes: notes,
            bars: bars,
            strums: strums,
            results: results,
            position: position,
            beatWidth: beatWidth,
            order: order,
            lanes: lanes,
          ),
        ),
      ]),
    );
  }
}

/// Vertical layout, as shares of the height: chord bubbles, the strip, then the strum lane.
class _Lanes {
  const _Lanes({required this.strums});

  final bool strums;

  double stripTop(Size s) => s.height * 0.24;
  double stripBottom(Size s) => s.height * (strums ? 0.84 : 0.98);

  /// Row of [string] within the strip, in [order].
  double y(Size s, int string, StringOrder order) {
    final top = stripTop(s), h = stripBottom(s) - top;
    return top + h * (0.1 + 0.8 * order.row(string) / 5);
  }

  double rowGap(Size s) => (stripBottom(s) - stripTop(s)) * 0.8 / 5;
}

const _strip = Color(0xFF2A1C14), _stripDark = Color(0xFF1C130E), _glow = Color(0xFFF0B27A);
const _right = Color(0xFF7FDCA4), _missed = Color(0xFFF08A84);

class _StripPainter extends CustomPainter {
  _StripPainter({required this.order, required this.lanes});

  final StringOrder order;
  final _Lanes lanes;

  @override
  void paint(Canvas canvas, Size size) {
    final strip = Rect.fromLTRB(0, lanes.stripTop(size), size.width, lanes.stripBottom(size));
    canvas.drawRRect(
      RRect.fromRectAndRadius(strip, const Radius.circular(14)),
      Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_strip, _stripDark]).createShader(strip),
    );
    // Behind the play line, a soft glow over what has just been played.
    final playX = size.width * TabHighway.playLine;
    final trail = Rect.fromLTRB(playX - size.width * 0.14, strip.top, playX, strip.bottom);
    canvas.drawRect(
      trail,
      Paint()..shader = LinearGradient(colors: [_glow.withValues(alpha: 0), _glow.withValues(alpha: 0.22)]).createShader(trail),
    );
    for (var s = 1; s <= 6; s++) {
      final y = lanes.y(size, s, order);
      final width = 1.1 + (s - 1) * 0.55;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), Paint()
        ..color = s <= 3 ? const Color(0xFFEDEAE4) : const Color(0xFFC9C1B4)
        ..strokeWidth = width);
      if (s >= 4) {
        // Wound strings: a twist drawn along them.
        final twist = Paint()
          ..color = const Color(0xFF7D746A)
          ..strokeWidth = 0.8;
        for (var x = 0.0; x < size.width; x += 2.6) {
          canvas.drawLine(Offset(x, y - width / 2), Offset(x + 1.3, y + width / 2), twist);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_StripPainter old) => old.order != order || old.lanes.strums != lanes.strums;
}

class _NotesPainter extends CustomPainter {
  _NotesPainter({
    required this.notes,
    required this.bars,
    required this.strums,
    required this.results,
    required this.position,
    required this.beatWidth,
    required this.order,
    required this.lanes,
  }) : super(repaint: position);

  final List<HighwayNote> notes;
  final List<double> bars;
  final List<HighwayStrum> strums;
  final List<bool?> results;
  final ValueListenable<double> position;
  final double beatWidth;
  final StringOrder order;
  final _Lanes lanes;

  @override
  void paint(Canvas canvas, Size size) {
    final now = position.value;
    final playX = size.width * TabHighway.playLine;
    double x(double beat) => playX + (beat - now) * beatWidth;
    // Only what's on screen: a song is hundreds of notes, and this repaints every frame.
    final from = now - playX / beatWidth - 1, to = now + (size.width - playX) / beatWidth + 1;
    final top = lanes.stripTop(size), bottom = lanes.stripBottom(size);

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final barLine = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 1.5;
    for (final b in bars) {
      if (b < from || b > to) continue;
      canvas.drawLine(Offset(x(b), top), Offset(x(b), bottom), barLine);
    }

    // The play line, glowing, under the notes so the one on it can be read.
    final line = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(playX, (top + bottom) / 2), width: 6, height: bottom - top + 10), const Radius.circular(3));
    canvas.drawRRect(line, Paint()
      ..color = _glow.withValues(alpha: 0.6)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    canvas.drawRRect(line, Paint()..color = _glow);

    final gap = lanes.rowGap(size);
    final tileH = gap * 0.9;
    // The note at the play line lights up: the last one reached, while it lasts.
    var lit = -1;
    for (var i = _firstFrom(notes.length, (i) => notes[i].beat, from); i < notes.length && notes[i].beat <= to; i++) {
      if (notes[i].beat <= now + 0.02) lit = i;
    }
    if (lit >= 0 && now - notes[lit].beat > 1.5) lit = -1;
    for (var i = _firstFrom(notes.length, (i) => notes[i].beat, from); i < notes.length && notes[i].beat <= to; i++) {
      final note = notes[i];
      final nx = x(note.beat);
      final passed = i < lit || (lit < 0 && note.beat < now);
      final result = i < results.length ? results[i] : null;
      final label = note.label;
      if (label != null) _bubble(canvas, label, Offset(nx, top - size.height * 0.03), size.height * 0.1, faded: passed);
      final fill = switch (result) { true => _right, false => _missed, null => i == lit ? _glow : Colors.white };
      for (final MapEntry(key: string, value: fret) in note.frets.entries) {
        // Judged notes keep their colour; only unjudged ones fade once passed.
        _tile(canvas, '$fret', Offset(nx, lanes.y(size, string, order)), tileH, fill: fill, faded: passed && result == null);
      }
      for (final string in note.muted) {
        _label(canvas, '×', Offset(nx, lanes.y(size, string, order)), tileH * 0.75, const Color(0xFFFF8A80).withValues(alpha: passed ? 0.4 : 1));
      }
    }

    if (strums.isNotEmpty) {
      final laneY = (bottom + size.height) / 2, len = (size.height - bottom) * 0.62;
      for (var i = _firstFrom(strums.length, (i) => strums[i].beat, from); i < strums.length && strums[i].beat <= to; i++) {
        final st = strums[i];
        final sx = x(st.beat);
        final color = (st.accent ? _glow : kMuted).withValues(alpha: st.beat < now - 0.05 ? 0.35 : 1);
        if (st.muted) {
          _label(canvas, '×', Offset(sx, laneY), len, color);
          continue;
        }
        final tip = Offset(sx, laneY + (st.down ? len / 2 : -len / 2)), tail = Offset(sx, laneY - (st.down ? len / 2 : -len / 2));
        final pen = Paint()
          ..color = color
          ..strokeWidth = st.accent ? 3 : 2
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(tail, tip, pen);
        final dir = st.down ? -1.0 : 1.0;
        canvas.drawLine(tip, tip + Offset(-len * 0.25, dir * len * 0.3), pen);
        canvas.drawLine(tip, tip + Offset(len * 0.25, dir * len * 0.3), pen);
      }
    }

    canvas.restore();
  }

  /// Index of the first of [length] items whose [beatOf] is at least [beat] (they're in order).
  static int _firstFrom(int length, double Function(int) beatOf, double beat) {
    var lo = 0, hi = length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (beatOf(mid) < beat) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  void _tile(Canvas canvas, String text, Offset center, double h, {required Color fill, required bool faded}) {
    final tp = _laidOut(text, h * 0.66, const Color(0xFF1F1B18));
    final rect = RRect.fromRectAndRadius(Rect.fromCenter(center: center, width: math.max(h, tp.width + h * 0.45), height: h), Radius.circular(h * 0.28));
    if (!faded) canvas.drawRRect(rect.shift(const Offset(0, 2)), Paint()..color = Colors.black.withValues(alpha: 0.35));
    canvas.drawRRect(rect, Paint()..color = fill.withValues(alpha: faded ? 0.4 : 1));
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  void _bubble(Canvas canvas, String text, Offset tip, double fontSize, {required bool faded}) {
    final tp = _laidOut(text, fontSize, Colors.white);
    final h = fontSize * 1.5;
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: tip - Offset(0, h / 2 + fontSize * 0.3), width: tp.width + fontSize * 0.9, height: h),
      Radius.circular(fontSize * 0.4),
    );
    final paint = Paint()..color = kText.withValues(alpha: faded ? 0.35 : 1);
    canvas.drawRRect(body, paint);
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx - fontSize * 0.3, body.bottom - 1)
        ..lineTo(tip.dx + fontSize * 0.3, body.bottom - 1)
        ..lineTo(tip.dx, tip.dy)
        ..close(),
      paint,
    );
    tp.paint(canvas, body.center - Offset(tp.width / 2, tp.height / 2));
  }

  void _label(Canvas canvas, String text, Offset center, double fontSize, Color color) {
    final tp = _laidOut(text, fontSize, color);
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  // The same few fret numbers and chord names repeat all through a song; laying text out is most
  // of the cost of painting it, and this paints every frame.
  static final _cache = <(String, double, Color), TextPainter>{};

  static TextPainter _laidOut(String text, double size, Color color) {
    if (_cache.length >= 256) {
      for (final tp in _cache.values) {
        tp.dispose();
      }
      _cache.clear();
    }
    return _cache[(text, size, color)] ??= TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontSize: size, color: color, fontWeight: FontWeight.w800)),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  @override
  bool shouldRepaint(_NotesPainter old) =>
      old.notes != notes ||
      old.bars != bars ||
      old.strums != strums ||
      old.results != results ||
      old.position != position ||
      old.beatWidth != beatWidth ||
      old.order != order;
}
