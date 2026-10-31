import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../music/chord.dart';
import '../../progress/progress_store.dart';

/// A chord on a drawn guitar neck, the way it looks on a teacher's guitar facing you: headstock
/// on the right, low E along the top, frets closing up towards the body, and a fingertip just
/// behind each fret it presses. Open and muted strings are marked beside the nut. Mirrored for
/// left-handed players.
class NeckView extends StatelessWidget {
  const NeckView({super.key, required this.chord, this.frets = 5, this.aspectRatio = 2.6});

  final Chord chord;

  /// How many frets show, from the chord's first.
  final int frets;

  /// Width over height: small cards show fewer frets, bigger.
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    final left = context.select<ProgressStore, bool>((p) => p.leftHanded);
    return Semantics(
      label: '${chord.name} on the guitar neck',
      child: AspectRatio(aspectRatio: aspectRatio, child: CustomPaint(painter: _NeckPainter(chord, frets: frets, leftHanded: left))),
    );
  }
}

/// Where things sit on the drawn neck (right-handed; the painter mirrors it for left-handers).
class NeckLayout {
  NeckLayout(this.size, {required this.baseFret, this.frets = 5}) {
    // Real fret spacing: each fret is 2^(1/12) closer to the next than the last. Fit the wires
    // from [baseFret] - 1 to [last] into the board, leaving part of one more fret on the left.
    double fromNut(int n) => 1 - math.pow(2, -n / 12).toDouble();
    final first = fromNut(baseFret - 1), span = fromNut(last) - first;
    final scale = (nutX - size.width * 0.07) / span;
    _wires = [for (var n = baseFret - 1; n <= last; n++) nutX - (fromNut(n) - first) * scale];
  }

  final Size size;
  final int baseFret, frets;

  /// The last fret shown.
  int get last => baseFret + frets - 1;
  late final List<double> _wires;

  bool get openPosition => baseFret == 1;
  double get headstock => openPosition ? size.width * 0.075 : 0;
  double get nutWidth => openPosition ? size.width * 0.022 : 0;

  /// The nut's left edge, where fret 0 ends (the board's right end up the neck).
  double get nutX => size.width - headstock - nutWidth;

  double get boardTop => size.height * 0.1;
  double get boardBottom => size.height * 0.9;

  /// Wire of fret [n] (n = baseFret - 1 .. [last]); up the neck, baseFret - 1 is the board's end.
  double wire(int n) => _wires[n - (baseFret - 1)];

  /// Where a fingertip presses fret [fret]: just behind its wire, on the nut side.
  double finger(int fret) => wire(fret) + (wire(fret - 1) - wire(fret)) * 0.32;

  /// Middle of fret [fret]'s space, where inlay dots go.
  double space(int fret) => (wire(fret) + wire(fret - 1)) / 2;

  /// String [string] (1 = high e .. 6 = low E): low E along the top, as seen from the front.
  double y(int string) => boardTop + (boardBottom - boardTop) * (0.1 + 0.8 * (6 - string) / 5);

  /// Where open/muted marks go: on the headstock beside the nut, or past the board up the neck.
  double get marksX => openPosition ? nutX + nutWidth + headstock * 0.5 : size.width - size.width * 0.035;

  double get fingerRadius => math.min((boardBottom - boardTop) * 0.085, (wire(last - 1) - wire(last)) * 0.32);
}

class _NeckPainter extends CustomPainter {
  _NeckPainter(this.chord, {required this.frets, required this.leftHanded});

  final Chord chord;
  final int frets;
  final bool leftHanded;

  static const _board = Color(0xFF3A2A21), _boardDark = Color(0xFF261A14), _fret = Color(0xFFCFC8BC);
  static const _nut = Color(0xFFF1E9D8), _headstock = Color(0xFF1E1714), _tip = Color(0xFFFFF4E6);
  static const _tipText = Color(0xFF4A2C1A), _open = Color(0xFF7CD6A0), _muted = Color(0xFFFF8A80);

  @override
  void paint(Canvas canvas, Size size) {
    if (leftHanded) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    final base = chord.baseFret;
    final at = NeckLayout(size, baseFret: base, frets: frets);
    final top = at.boardTop, bottom = at.boardBottom;

    final board = Rect.fromLTRB(0, top, at.nutX, bottom);
    canvas.drawRect(
      board,
      Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_board, _boardDark]).createShader(board),
    );
    // A little grain along the board.
    final grain = Paint()
      ..color = Colors.white.withValues(alpha: 0.035)
      ..strokeWidth = 1;
    for (var k = 1; k < 9; k++) {
      final y = top + (bottom - top) * k / 9 + math.sin(k * 1.7) * 2;
      canvas.drawLine(Offset(0, y), Offset(at.nutX, y + math.cos(k) * 1.5), grain);
    }
    if (at.openPosition) {
      canvas.drawRRect(
        RRect.fromRectAndCorners(Rect.fromLTRB(at.nutX, top - size.height * 0.06, size.width, bottom + size.height * 0.06),
            topRight: const Radius.circular(10), bottomRight: const Radius.circular(10)),
        Paint()..color = _headstock,
      );
      canvas.drawRect(Rect.fromLTRB(at.nutX, top - 1, at.nutX + at.nutWidth, bottom + 1), Paint()..color = _nut);
    }

    final inlay = Paint()..color = const Color(0xFFE9E1D3).withValues(alpha: 0.85);
    final r = (bottom - top) * 0.05;
    for (var f = base; f <= at.last; f++) {
      final x = at.space(f);
      if (f % 12 == 0) {
        canvas.drawCircle(Offset(x, top + (bottom - top) * 0.3), r, inlay);
        canvas.drawCircle(Offset(x, top + (bottom - top) * 0.7), r, inlay);
      } else if (const {3, 5, 7, 9}.contains(f % 12)) {
        canvas.drawCircle(Offset(x, (top + bottom) / 2), r, inlay);
      }
    }
    for (var n = base; n <= at.last; n++) {
      final x = at.wire(n);
      canvas.drawLine(Offset(x, top), Offset(x, bottom), Paint()
        ..color = _fret
        ..strokeWidth = math.max(1.5, size.width * 0.007));
    }

    // Strings: the three plain ones bright and thin; the wound ones thicker, with a twist drawn on.
    for (var s = 1; s <= 6; s++) {
      final y = at.y(s);
      final width = size.height * (0.012 + (s - 1) * 0.005);
      final end = at.openPosition ? size.width - at.headstock * 0.2 : size.width;
      canvas.drawLine(Offset(0, y), Offset(end, y), Paint()
        ..color = s <= 3 ? const Color(0xFFEDEAE4) : const Color(0xFFC9C1B4)
        ..strokeWidth = width);
      if (s >= 4) {
        final twist = Paint()
          ..color = const Color(0xFF8D8478)
          ..strokeWidth = 0.8;
        for (var x = 0.0; x < end; x += 2.4) {
          canvas.drawLine(Offset(x, y - width / 2), Offset(x + 1.2, y + width / 2), twist);
        }
      }
    }

    final tipR = at.fingerRadius;
    final barre = chord.barre;
    if (barre != null) {
      final x = at.finger(barre.fret);
      final a = at.y(barre.from), b = at.y(barre.to);
      final rect = RRect.fromRectAndRadius(
          Rect.fromLTRB(x - tipR, math.min(a, b) - tipR, x + tipR, math.max(a, b) + tipR), Radius.circular(tipR));
      canvas.drawRRect(rect.shift(const Offset(0, 1.5)), Paint()..color = Colors.black.withValues(alpha: 0.35));
      canvas.drawRRect(rect, Paint()..color = _tip);
      _finger(canvas, '1', Offset(x, (a + b) / 2), tipR);
    }
    for (var i = 0; i < 6; i++) {
      final string = 6 - i;
      final fret = chord.frets[i];
      final y = at.y(string);
      if (fret < 0) {
        _text(canvas, '×', Offset(at.marksX, y), tipR * 1.6, _muted);
      } else if (fret == 0) {
        canvas.drawCircle(Offset(at.marksX, y), tipR * 0.55, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.2, tipR * 0.22)
          ..color = _open);
      } else {
        final finger = chord.fingers[i];
        if (barre != null && finger == 1 && fret == barre.fret) continue;
        final c = Offset(at.finger(fret), y);
        canvas.drawCircle(c + const Offset(0, 1.5), tipR, Paint()..color = Colors.black.withValues(alpha: 0.35));
        canvas.drawCircle(c, tipR, Paint()..color = _tip);
        if (finger > 0) _finger(canvas, '$finger', c, tipR);
      }
    }
    if (!at.openPosition) _text(canvas, '${base}fr', Offset(at.space(base), bottom + size.height * 0.06), size.height * 0.09, _tipText);
  }

  /// A finger number on its fingertip, left out where the tip is too small to read it.
  void _finger(Canvas canvas, String finger, Offset center, double r) {
    if (r * 1.3 >= 7) _text(canvas, finger, center, r * 1.3, _tipText);
  }

  /// Text reads the right way round even when the neck is mirrored.
  void _text(Canvas canvas, String s, Offset center, double fontSize, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: fontSize, color: color, fontWeight: FontWeight.w800)),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(center.dx, center.dy);
    if (leftHanded) canvas.scale(-1, 1);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
    tp.dispose();
  }

  @override
  bool shouldRepaint(_NeckPainter old) => old.chord != chord || old.frets != frets || old.leftHanded != leftHanded;
}
