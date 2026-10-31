import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../music/notes.dart';
import '../../progress/progress_store.dart';
import '../theme.dart';

/// A horizontal fretboard section highlighting [target], its strings in the same order as the
/// tabs (Me › String order).
/// [upcoming] notes are drawn faintly so the learner can see where the melody goes.
class Fretboard extends StatelessWidget {
  const Fretboard({super.key, required this.target, this.upcoming = const [], this.showName = true});

  final FretNote target;
  final List<FretNote> upcoming;

  /// Write the note's name on its dot (not when asking for it).
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final (left, order) = context.select<ProgressStore, (bool, StringOrder)>((p) => (p.leftHanded, p.stringOrder));
    final frets = [target, ...upcoming].map((n) => n.fret);
    final lo = frets.reduce(math.min), hi = frets.reduce(math.max);
    // Fretted columns shown: first..last. Fret 0 has its own column left of the nut.
    final first = lo <= 1 ? 1 : lo - 1;
    final last = math.max(first + 4, hi + 1);
    return AspectRatio(
      aspectRatio: 2.4,
      child: CustomPaint(
          painter: _FretboardPainter(target, upcoming, first, last, leftHanded: left, order: order, showName: showName)),
    );
  }
}

class _FretboardPainter extends CustomPainter {
  _FretboardPainter(this.target, this.upcoming, this.first, this.last,
      {required this.leftHanded, required this.order, required this.showName});

  final FretNote target;
  final List<FretNote> upcoming;
  final int first, last;
  final bool leftHanded, showName;
  final StringOrder order;

  @override
  void paint(Canvas canvas, Size size) {
    final openW = size.width * 0.15;
    final boardL = openW;
    final boardW = size.width - boardL - 4;
    final fretW = boardW / (last - first + 1);
    final top = size.height * 0.1, h = size.height * 0.72;
    final dy = h / 5;
    double y(int string) => top + order.row(string) * dy;
    double mirror(double x) => leftHanded ? size.width - x : x;
    double x(int fret) => mirror(fret == 0 ? openW * 0.66 : boardL + (fret - first + 0.5) * fretW);

    final board = Rect.fromLTWH(boardL, top - 8, boardW, h + 16);
    canvas.drawRRect(
      RRect.fromRectAndRadius(leftHanded ? board.translate(size.width - 2 * boardL - boardW, 0) : board, const Radius.circular(6)),
      Paint()..color = const Color(0xFFEBDCC9),
    );
    for (var k = 0; k <= last - first + 1; k++) {
      final fx = mirror(boardL + k * fretW);
      final nut = k == 0 && first == 1;
      canvas.drawLine(
        Offset(fx, top - 8),
        Offset(fx, top + h + 8),
        Paint()
          ..color = nut ? kText : const Color(0xFFB4A08C)
          ..strokeWidth = nut ? 6 : 2,
      );
    }
    for (var f = first; f <= last; f++) {
      if (const {3, 5, 7, 9, 12, 15}.contains(f)) {
        _label(canvas, '$f', Offset(x(f), top + h + size.height * 0.11), size.height * 0.075, kMuted);
      }
    }
    for (var s = 1; s <= 6; s++) {
      final x0 = leftHanded ? size.width - boardL - boardW : boardL;
      canvas.drawLine(
        Offset(x0, y(s)),
        Offset(x0 + boardW, y(s)),
        Paint()
          ..color = const Color(0xFF8C7868)
          ..strokeWidth = 0.8 + (s - 1) * 0.35,
      );
      _label(canvas, stringLetters[s]!, Offset(mirror(openW * 0.16), y(s)), size.height * 0.065, kMuted.withValues(alpha: 0.7));
    }
    final r = math.min(dy * 0.45, fretW * 0.33);
    for (final n in upcoming.take(3)) {
      if (n == target) continue;
      canvas.drawCircle(Offset(x(n.fret), y(n.string)), r * 0.75, Paint()..color = kAccent.withValues(alpha: 0.28));
    }
    final c = Offset(x(target.fret), y(target.string));
    canvas.drawCircle(c, r * 1.45, Paint()..color = kAccent.withValues(alpha: 0.22));
    canvas.drawCircle(c, r, Paint()..color = kAccent);
    if (showName) _label(canvas, noteName(target.midi), c, r * 1.0, kOnAccent);
  }

  void _label(Canvas canvas, String s, Offset center, double fontSize, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: fontSize, color: color, fontWeight: FontWeight.w800)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_FretboardPainter old) =>
      old.target != target ||
      old.first != first ||
      old.last != last ||
      old.leftHanded != leftHanded ||
      old.upcoming != upcoming ||
      old.order != order ||
      old.showName != showName;
}
