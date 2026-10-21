import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../music/chord.dart';
import '../../progress/progress_store.dart';
import '../theme.dart';

/// A standard chord box: string 6 on the left (mirrored for left-handed players), dots with
/// finger numbers, X/O above the nut, and a fret label when the shape sits up the neck.
class ChordDiagram extends StatelessWidget {
  const ChordDiagram({super.key, required this.chord, this.width = 140, this.showName = false});

  final Chord chord;
  final double width;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final left = context.select<ProgressStore, bool>((p) => p.leftHanded);
    final diagram = SizedBox(
      width: width,
      height: width * 1.2,
      child: CustomPaint(painter: _ChordPainter(chord, leftHanded: left)),
    );
    if (!showName) return Semantics(label: '${chord.name} chord diagram', child: diagram);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(chord.symbol, style: TextStyle(fontSize: width * 0.16, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      diagram,
    ]);
  }
}

class _ChordPainter extends CustomPainter {
  _ChordPainter(this.chord, {required this.leftHanded});

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
    } else {
      _text(canvas, '${base}fr', Offset(left * 0.45, top + dy / 2), size.width * 0.1, kMuted);
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

  void _text(Canvas canvas, String s, Offset center, double fontSize, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: fontSize, color: color, fontWeight: FontWeight.w800)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_ChordPainter old) => old.chord != chord || old.leftHanded != leftHanded;
}
