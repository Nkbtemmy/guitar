import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../music/chord.dart';
import '../../music/notes.dart';
import '../../progress/progress_store.dart';
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

/// Guitar tablature: six horizontal lines with fret numbers sitting on them, low E on top and high
/// e at the bottom (or the other way up: Me › String order). [current] is highlighted; columns before
/// it are marked done, and the label it's playing under (a chord name over a bar) rides on top of
/// it. Long staffs scroll horizontally and keep the current column in view.
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
    this.rangeStart = -1,
    this.rangeEnd = -1,
    this.bars = const [],
    this.onTapColumn,
  });

  final List<TabColumn> columns;
  final int current;

  /// Color columns before [current] as completed.
  final bool markDone;

  /// Stretch columns to fill the available width (otherwise each is [columnWidth] wide).
  final bool expand;
  final double columnWidth, lineGap, fontSize;

  /// Columns [rangeStart]..[rangeEnd] are shaded (a practice loop); -1 for none.
  final int rangeStart, rangeEnd;

  /// Columns that start a new bar; a bar line is drawn before each.
  final List<int> bars;

  /// Called with the column index when the staff is tapped.
  final ValueChanged<int>? onTapColumn;

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
    final order = context.select<ProgressStore, StringOrder>((p) => p.stringOrder);
    return LayoutBuilder(builder: (context, constraints) {
      final natural = TabStaff.gutter + widget.columns.length * widget.columnWidth + 8;
      final width = widget.expand && constraints.hasBoundedWidth && natural < constraints.maxWidth ? constraints.maxWidth : natural;
      final columnWidth = (width - TabStaff.gutter - 8) / widget.columns.length;
      final painter = _TabPainter(
        columns: widget.columns,
        current: widget.current,
        markDone: widget.markDone,
        columnWidth: columnWidth,
        lineGap: widget.lineGap,
        fontSize: widget.fontSize,
        labels: _labels,
        rangeStart: widget.rangeStart,
        rangeEnd: widget.rangeEnd,
        bars: widget.bars,
        order: order,
      );
      Widget staff = SizedBox(width: width, height: height, child: CustomPaint(painter: painter));
      final onTap = widget.onTapColumn;
      if (onTap != null) {
        staff = GestureDetector(
          onTapUp: (d) {
            final col = ((d.localPosition.dx - TabStaff.gutter) / columnWidth).floor();
            if (col >= 0 && col < widget.columns.length) onTap(col);
          },
          child: staff,
        );
      }
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
    required this.rangeStart,
    required this.rangeEnd,
    required this.bars,
    required this.order,
  });

  final List<TabColumn> columns;
  final int current, rangeStart, rangeEnd;
  final List<int> bars;
  final StringOrder order;

  final bool markDone, labels;
  final double columnWidth, lineGap, fontSize;

  @override
  void paint(Canvas canvas, Size size) {
    final top = labels ? lineGap * 1.6 : lineGap * 0.6;
    double y(int string) => top + order.row(string) * lineGap;
    double x(int col) => TabStaff.gutter + (col + 0.5) * columnWidth;
    final right = TabStaff.gutter + columns.length * columnWidth;
    // Only the columns in view (plus one each side): a long tab is hundreds of columns, and the
    // staff repaints on every frame while it scrolls to follow playback.
    final view = canvas.getLocalClipBounds();
    final first = math.max(0, ((view.left - TabStaff.gutter) / columnWidth).floor() - 1);
    final last = math.min(columns.length - 1, ((view.right - TabStaff.gutter) / columnWidth).ceil() + 1);

    if (rangeStart >= 0 && rangeEnd >= rangeStart) {
      canvas.drawRect(
        Rect.fromLTRB(x(rangeStart) - columnWidth / 2, top - lineGap * 0.6, x(rangeEnd) + columnWidth / 2, top + lineGap * 5.6),
        Paint()..color = kSurfaceHigh,
      );
    }
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
    double numberWidth(String t) => fontSize * (t.length > 1 ? 1.3 : 0.9);
    for (var s = 1; s <= 6; s++) {
      // Leave a gap in the line around each number, the way printed tab does, so the staff
      // reads on any background (cards, the highlighted column).
      var from = first == 0 ? TabStaff.gutter - 4 : x(first) - columnWidth / 2;
      final to = last == columns.length - 1 ? right : x(last) + columnWidth / 2;
      for (var c = first; c <= last; c++) {
        final t = columns[c].textFor(s);
        if (t == null) continue;
        final half = numberWidth(t) / 2;
        if (x(c) - half > from) canvas.drawLine(Offset(from, y(s)), Offset(x(c) - half, y(s)), line);
        from = x(c) + half;
      }
      if (from < to) canvas.drawLine(Offset(from, y(s)), Offset(to, y(s)), line);
      _text(canvas, stringLetters[s]!, Offset(TabStaff.gutter / 2 - 2, y(s)), fontSize * 0.75, kMuted, FontWeight.w700);
    }
    for (final b in bars) {
      if (b <= 0 || b >= columns.length) continue;
      final bx = TabStaff.gutter + b * columnWidth;
      canvas.drawLine(Offset(bx, y(1)), Offset(bx, y(6)), line);
    }
    canvas.drawLine(Offset(TabStaff.gutter - 4, y(1)), Offset(TabStaff.gutter - 4, y(6)), line..strokeWidth = 2.5);
    canvas.drawLine(Offset(right, y(1)), Offset(right, y(6)), line..strokeWidth = 2.5);

    // The label the current column plays under: its own, or the last one before it.
    var activeLabel = -1;
    for (var c = 0; c <= current && c < columns.length; c++) {
      if (columns[c].label != null) activeLabel = c;
    }
    for (var c = first; c <= last; c++) {
      final col = columns[c];
      final isCurrent = c == current;
      final done = markDone && current >= 0 && c < current;
      final color = isCurrent ? kAccent : (done ? kSuccess : kText);
      // The playing label rides on the cursor (drawn below), so skip it where they meet.
      if (col.label != null && !(c == activeLabel && isCurrent)) {
        _text(canvas, col.label!, Offset(x(c), lineGap * 0.7), fontSize * 0.95, kMuted, FontWeight.w800);
      }
      for (var s = 1; s <= 6; s++) {
        final t = col.textFor(s);
        if (t == null) continue;
        final muted = t == 'x';
        _text(canvas, t, Offset(x(c), y(s)), muted ? fontSize * 0.85 : fontSize, muted ? kMiss : color, FontWeight.w800);
      }
    }
    if (activeLabel >= 0 && current < columns.length) _cursorLabel(canvas, columns[activeLabel].label!, x(current));
  }

  /// The chord being played, in a pill on top of the moving cursor.
  void _cursorLabel(Canvas canvas, String label, double x) {
    final center = Offset(x, lineGap * 0.7);
    final width = math.max(columnWidth * 0.9, fontSize * (0.7 * label.length + 1.2));
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromCenter(center: center, width: width, height: fontSize * 1.6), const Radius.circular(20)),
      Paint()..color = kAccent,
    );
    _text(canvas, label, center, fontSize * 0.95, kOnAccent, FontWeight.w800);
  }

  // Laid-out text by content and style. The same few fret numbers and chord names repeat all
  // through a tab, and laying text out is most of the cost of painting it.
  static final _laidOut = <(String, double, Color, FontWeight), TextPainter>{};

  void _text(Canvas canvas, String s, Offset center, double size, Color color, FontWeight weight) {
    if (_laidOut.length >= 512) {
      for (final tp in _laidOut.values) {
        tp.dispose();
      }
      _laidOut.clear();
    }
    final tp = _laidOut[(s, size, color, weight)] ??= TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontWeight: weight, fontFeatures: const [FontFeature.tabularFigures()])),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_TabPainter old) =>
      old.columns != columns ||
      old.current != current ||
      old.markDone != markDone ||
      old.columnWidth != columnWidth ||
      old.rangeStart != rangeStart ||
      old.rangeEnd != rangeEnd ||
      old.bars != bars ||
      old.order != order;
}
