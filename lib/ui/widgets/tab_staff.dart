import 'package:flutter/material.dart';

import '../../music/chord.dart';
import '../../music/notes.dart';
import '../theme.dart';

/// One vertical slice of tablature: the fret to play on each string, strings to mute, and an
/// optional label above (usually a chord name).
class TabColumn {
  const TabColumn(this.frets, {this.muted = const {}, this.label});

  /// String number (1 = high e .. 6 = low E) to fret.
  final Map<int, int> frets;
  final Set<int> muted;
  final String? label;

  factory TabColumn.chord(Chord chord, {bool label = true}) => TabColumn(
        {for (var i = 0; i < 6; i++) if (chord.frets[i] >= 0) 6 - i: chord.frets[i]},
        muted: {for (var i = 0; i < 6; i++) if (chord.frets[i] < 0) 6 - i},
        label: label ? chord.symbol : null,
      );

  factory TabColumn.note(FretNote note) => TabColumn({note.string: note.fret});

  /// The text shown on [string]: a fret number, 'x' for muted, or null for an empty line.
  String? textFor(int string) => frets.containsKey(string) ? '${frets[string]}' : (muted.contains(string) ? 'x' : null);
}

/// Guitar tablature: six horizontal lines, high e on top, with fret numbers sitting on the
/// lines. [current] is highlighted; columns before it are marked done. Long staffs scroll
/// horizontally and keep the current column in view.
class TabStaff extends StatefulWidget {
  const TabStaff({
    super.key,
    required this.columns,
    this.current = -1,
    this.markDone = false,
    this.expand = false,
    this.columnWidth = 40,
    this.lineGap = 18,
    this.fontSize = 15,
  });

  final List<TabColumn> columns;
  final int current;

  /// Color columns before [current] as completed.
  final bool markDone;

  /// Stretch columns to fill the available width (otherwise each is [columnWidth] wide).
  final bool expand;
  final double columnWidth, lineGap, fontSize;

  static const gutter = 26.0;

  /// Total height for a given line gap (labels row + six lines).
  static double heightFor(double lineGap, {bool labels = true}) => (labels ? lineGap * 1.6 : lineGap * 0.6) + lineGap * 5 + lineGap * 0.8;

  @override
  State<TabStaff> createState() => _TabStaffState();
}

class _TabStaffState extends State<TabStaff> {
  final _scroll = ScrollController();

  bool get _labels => widget.columns.any((c) => c.label != null);

  @override
  void didUpdateWidget(TabStaff old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current) WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
  }

  void _follow() {
    if (!_scroll.hasClients || widget.current < 0) return;
    final x = TabStaff.gutter + (widget.current + 0.5) * widget.columnWidth - _scroll.position.viewportDimension / 2;
    _scroll.animateTo(x.clamp(0.0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = TabStaff.heightFor(widget.lineGap, labels: _labels);
    return LayoutBuilder(builder: (context, constraints) {
      final natural = TabStaff.gutter + widget.columns.length * widget.columnWidth + 8;
      final width = widget.expand && constraints.hasBoundedWidth && natural < constraints.maxWidth ? constraints.maxWidth : natural;
      final painter = _TabPainter(
        columns: widget.columns,
        current: widget.current,
        markDone: widget.markDone,
        columnWidth: (width - TabStaff.gutter - 8) / widget.columns.length,
        lineGap: widget.lineGap,
        fontSize: widget.fontSize,
        labels: _labels,
      );
      final staff = SizedBox(width: width, height: height, child: CustomPaint(painter: painter));
      return Semantics(
        label: 'Tab: ${[for (final c in widget.columns) c.label ?? _describe(c)].join(', ')}',
        child: natural <= constraints.maxWidth
            ? staff
            : SingleChildScrollView(controller: _scroll, scrollDirection: Axis.horizontal, child: staff),
      );
    });
  }

  static String _describe(TabColumn c) => [for (final e in c.frets.entries) 'string ${e.key} fret ${e.value}'].join(' and ');
}

class _TabPainter extends CustomPainter {
  _TabPainter({
    required this.columns,
    required this.current,
    required this.markDone,
    required this.columnWidth,
    required this.lineGap,
    required this.fontSize,
    required this.labels,
  });

  final List<TabColumn> columns;
  final int current;
  final bool markDone, labels;
  final double columnWidth, lineGap, fontSize;

  @override
  void paint(Canvas canvas, Size size) {
    final top = labels ? lineGap * 1.6 : lineGap * 0.6;
    double y(int string) => top + (string - 1) * lineGap;
    double x(int col) => TabStaff.gutter + (col + 0.5) * columnWidth;
    final right = TabStaff.gutter + columns.length * columnWidth;

    if (current >= 0 && current < columns.length) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(x(current), top + 2.5 * lineGap), width: columnWidth * 0.86, height: lineGap * 6.2),
          const Radius.circular(8),
        ),
        Paint()..color = kAccent.withValues(alpha: 0.18),
      );
    }
    final line = Paint()
      ..color = const Color(0xFF6E655E)
      ..strokeWidth = 1.2;
    for (var s = 1; s <= 6; s++) {
      canvas.drawLine(Offset(TabStaff.gutter - 4, y(s)), Offset(right, y(s)), line);
      _text(canvas, stringLetters[s]!, Offset(TabStaff.gutter / 2 - 2, y(s)), fontSize * 0.75, kMuted, FontWeight.w700);
    }
    canvas.drawLine(Offset(TabStaff.gutter - 4, y(1)), Offset(TabStaff.gutter - 4, y(6)), line..strokeWidth = 2.5);
    canvas.drawLine(Offset(right, y(1)), Offset(right, y(6)), line..strokeWidth = 2.5);

    for (var c = 0; c < columns.length; c++) {
      final col = columns[c];
      final isCurrent = c == current;
      final done = markDone && current >= 0 && c < current;
      final color = isCurrent ? kAccent : (done ? kSuccess : kText);
      if (col.label != null) {
        _text(canvas, col.label!, Offset(x(c), lineGap * 0.7), fontSize * 0.95, isCurrent ? kAccent : kMuted, FontWeight.w800);
      }
      for (var s = 1; s <= 6; s++) {
        final t = col.textFor(s);
        if (t == null) continue;
        final muted = t == 'x';
        final w = fontSize * (t.length > 1 ? 1.3 : 0.9);
        // Cut the line behind the number, the way printed tab does.
        canvas.drawRect(Rect.fromCenter(center: Offset(x(c), y(s)), width: w, height: lineGap * 0.8), Paint()..color = kBackground);
        _text(canvas, t, Offset(x(c), y(s)), muted ? fontSize * 0.85 : fontSize, muted ? kMiss : color, FontWeight.w800);
      }
    }
  }

  void _text(Canvas canvas, String s, Offset center, double size, Color color, FontWeight weight) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontWeight: weight, fontFeatures: const [FontFeature.tabularFigures()])),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_TabPainter old) =>
      old.columns != columns || old.current != current || old.markDone != markDone || old.columnWidth != columnWidth;
}
