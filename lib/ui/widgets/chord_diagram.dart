import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../music/chord.dart';
import '../../music/notes.dart';
import '../../progress/progress_store.dart';
import '../theme.dart';

/// A chord diagram: dots with finger numbers, × and ○ beside the nut for muted and open strings,
/// mirrored for left-handed players. It faces the way the learner chose in Me › Chord charts:
/// upright like a chord book (string 6 on the left, frets numbered down the side), or sideways
/// like the guitar's neck (nut on the left, frets numbered left to right, strings in the same order
/// as the tabs).
class ChordDiagram extends StatelessWidget {
  const ChordDiagram({super.key, required this.chord, this.width = 140, this.showName = false, this.stringNames = true});

  final Chord chord;
  final double width;
  final bool showName;

  /// Sideways only: the string letters (e B G D A E) left of the nut.
  final bool stringNames;

  /// Height of a diagram [width] wide.
  static double heightFor(double width, ChordOrientation orientation) =>
      width * (orientation == ChordOrientation.sideways ? 1 / 1.2 : 1.2);

  @override
  Widget build(BuildContext context) {
    final (left, orientation, order) = context
        .select<ProgressStore, (bool, ChordOrientation, StringOrder)>((p) => (p.leftHanded, p.chordOrientation, p.stringOrder));
    final diagram = SizedBox(
      width: width,
      height: heightFor(width, orientation),
      child: CustomPaint(
        painter: orientation == ChordOrientation.sideways
            ? _SidewaysPainter(chord, leftHanded: left, names: stringNames, order: order)
            : _UprightPainter(chord, leftHanded: left),
      ),
    );
    if (!showName) return Semantics(label: '${chord.name} chord diagram', child: diagram);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(chord.symbol, style: TextStyle(fontSize: width * 0.16, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      diagram,
    ]);
  }
}

/// Where everything sits in a sideways diagram. Strings are rows spaced [gap] apart, in [order],
/// exactly as on a [TabStaff] with the same line gap and no labels, so a tab drawn beside it lines
/// up string for string. Frets are columns, counted from the nut.
class SidewaysChordLayout {
  SidewaysChordLayout(this.size,
      {required this.baseFret, this.names = true, this.leftHanded = false, this.order = StringOrder.lowOnTop})
      : gap = size.height / rows;

  /// Heights in [gap]s: margin, five string gaps, and the fret-number row.
  static const rows = 0.6 + 5 + 1.6;
  static const frets = 4;

  final Size size;
  final int baseFret;
  final bool names, leftHanded;
  final StringOrder order;
  final double gap;

  double get _namesWidth => names ? gap * 0.9 : 0;
  double get _openWidth => gap * 1.1;
  double get _nut => _namesWidth + _openWidth;
  double get fretWidth => (size.width - _nut - gap * 0.3) / frets;

  double _mirror(double x) => leftHanded ? size.width - x : x;

  /// Row of string [string] (1 = high e .. 6 = low E).
  double y(int string) => gap * (0.6 + order.row(string));

  /// Centre of [fret]'s space, where its dot goes; 0 or less is the open/muted column by the nut.
  double x(int fret) => _mirror(fret <= 0 ? _namesWidth + _openWidth * 0.45 : _nut + (fret - baseFret + 0.5) * fretWidth);

  /// The [k]th fret wire from the nut (0 is the nut itself).
  double wire(int k) => _mirror(_nut + k * fretWidth);

  double get namesX => _mirror(_namesWidth * 0.45);

  /// Where the fret numbers sit, under the bottom string.
  double get numbersY => gap * (0.6 + 5 + 0.95);

  double get dotRadius => math.min(gap * 0.44, fretWidth * 0.36);
}

class _SidewaysPainter extends CustomPainter {
  _SidewaysPainter(this.chord, {required this.leftHanded, required this.names, required this.order});

  final Chord chord;
  final bool leftHanded, names;
  final StringOrder order;

  @override
  void paint(Canvas canvas, Size size) {
    final base = chord.baseFret;
    final at = SidewaysChordLayout(size, baseFret: base, names: names, leftHanded: leftHanded, order: order);
    final g = at.gap;
    const frets = SidewaysChordLayout.frets;

    final wire = Paint()
      ..color = const Color(0xFF8C837B)
      ..strokeWidth = math.max(1, g * 0.1);
    for (var k = 0; k <= frets; k++) {
      canvas.drawLine(Offset(at.wire(k), at.y(1)), Offset(at.wire(k), at.y(6)), wire);
    }
    if (base == 1) {
      final nutWidth = g * 0.28;
      final x = at.wire(0) + (leftHanded ? 0 : -nutWidth);
      final top = math.min(at.y(1), at.y(6));
      canvas.drawRect(Rect.fromLTWH(x, top - wire.strokeWidth / 2, nutWidth, 5 * g + wire.strokeWidth), Paint()..color = kText);
    }
    // Strings get thicker towards low E, as on the guitar.
    for (var s = 1; s <= 6; s++) {
      canvas.drawLine(
        Offset(at.wire(0), at.y(s)),
        Offset(at.wire(frets), at.y(s)),
        Paint()
          ..color = const Color(0xFF8C837B)
          ..strokeWidth = g * (0.06 + (s - 1) * 0.025),
      );
      if (names) _text(canvas, stringLetters[s]!, Offset(at.namesX, at.y(s)), g * 0.55, kMuted);
    }
    for (var k = 0; k < frets; k++) {
      final fret = base + k;
      _text(canvas, '$fret', Offset(at.x(fret), at.numbersY), g * 0.6, k == 0 && base > 1 ? kText : kMuted);
    }

    final r = at.dotRadius;
    final barre = chord.barre;
    if (barre != null) {
      final x = at.x(barre.fret);
      final a = at.y(barre.from), b = at.y(barre.to);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(x - r, math.min(a, b) - r, x + r, math.max(a, b) + r), Radius.circular(r)),
        Paint()..color = kAccent,
      );
      _finger(canvas, '1', Offset(x, (a + b) / 2), r);
    }
    for (var i = 0; i < 6; i++) {
      final string = 6 - i;
      final fret = chord.frets[i];
      final y = at.y(string);
      if (fret < 0) {
        _text(canvas, '×', Offset(at.x(0), y), g * 0.8, kMiss);
      } else if (fret == 0) {
        canvas.drawCircle(
            Offset(at.x(0), y),
            g * 0.26,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = g * 0.09
              ..color = kSuccess);
      } else {
        final finger = chord.fingers[i];
        if (barre != null && finger == 1 && fret == barre.fret) continue;
        final c = Offset(at.x(fret), y);
        canvas.drawCircle(c, r, Paint()..color = kAccent);
        if (finger > 0) _finger(canvas, '$finger', c, r);
      }
    }
  }

  /// A finger number on its dot, left out where the dot is too small to read it.
  void _finger(Canvas canvas, String finger, Offset center, double r) {
    if (r * 1.25 >= 7) _text(canvas, finger, center, r * 1.25, kOnAccent);
  }

  @override
  bool shouldRepaint(_SidewaysPainter old) =>
      old.chord != chord || old.leftHanded != leftHanded || old.names != names || old.order != order;
}

class _UprightPainter extends CustomPainter {
  _UprightPainter(this.chord, {required this.leftHanded});

  final Chord chord;
  final bool leftHanded;
  static const frets = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final base = chord.baseFret;
    final top = size.height * 0.14;
    final left = size.width * 0.17;
    final right = size.width * 0.06;
    final gridW = size.width - left - right;
    final gridH = size.height - top - size.height * 0.04;
    final dx = gridW / 5;
    final dy = gridH / frets;
    double xFor(int index) => left + (leftHanded ? 5 - index : index) * dx;

    final line = Paint()
      ..color = const Color(0xFF8C837B)
      ..strokeWidth = size.width * 0.012;
    for (var i = 0; i < 6; i++) {
      canvas.drawLine(Offset(xFor(i), top), Offset(xFor(i), top + gridH), line);
    }
    for (var f = 0; f <= frets; f++) {
      final y = top + f * dy;
      canvas.drawLine(Offset(left, y), Offset(left + gridW, y), line);
    }
    if (base == 1) {
      canvas.drawRect(
          Rect.fromLTWH(left - line.strokeWidth / 2, top - size.height * 0.03, gridW + line.strokeWidth, size.height * 0.03),
          Paint()..color = kText);
    }
    // Fret numbers down the side; up the neck, the first one in full colour says where the shape sits.
    for (var f = 0; f < frets; f++) {
      _text(canvas, '${base + f}', Offset(left * 0.5, top + (f + 0.5) * dy), math.min(size.width * 0.09, dy * 0.5),
          f == 0 && base > 1 ? kText : kMuted);
    }

    final dotR = dx * 0.38;
    final barre = chord.barre;
    if (barre != null) {
      final a = xFor(6 - barre.from), b = xFor(6 - barre.to);
      final y = top + (barre.fret - base + 0.5) * dy;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTRB((a < b ? a : b) - dotR, y - dotR, (a < b ? b : a) + dotR, y + dotR), Radius.circular(dotR)),
        Paint()..color = kAccent,
      );
      _text(canvas, '1', Offset((a + b) / 2, y), dotR * 1.2, kOnAccent);
    }

    for (var i = 0; i < 6; i++) {
      final fret = chord.frets[i];
      final x = xFor(i);
      if (fret < 0) {
        _text(canvas, '×', Offset(x, top * 0.45), size.width * 0.12, kMiss);
      } else if (fret == 0) {
        canvas.drawCircle(
            Offset(x, top * 0.45),
            dx * 0.2,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = size.width * 0.014
              ..color = kSuccess);
      } else {
        final finger = chord.fingers[i];
        if (barre != null && finger == 1 && fret == barre.fret) continue;
        final c = Offset(x, top + (fret - base + 0.5) * dy);
        canvas.drawCircle(c, dotR, Paint()..color = kAccent);
        if (finger > 0) _text(canvas, '$finger', c, dotR * 1.2, kOnAccent);
      }
    }
  }

  @override
  bool shouldRepaint(_UprightPainter old) => old.chord != chord || old.leftHanded != leftHanded;
}

void _text(Canvas canvas, String s, Offset center, double fontSize, Color color) {
  final tp = TextPainter(
    text: TextSpan(text: s, style: TextStyle(fontSize: fontSize, color: color, fontWeight: FontWeight.w800)),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  tp.dispose();
}
