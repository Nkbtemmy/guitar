import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../music/chord.dart';
import '../../progress/progress_store.dart';
import 'chord_diagram.dart';
import 'tab_staff.dart';

/// A chord as six-line tab for one chord, sized to sit next to a diagram of [height].
class ChordTab extends StatelessWidget {
  const ChordTab({super.key, required this.chord, required this.height, this.label = true});

  final Chord chord;
  final double height;
  final bool label;

  @override
  Widget build(BuildContext context) {
    // heightFor = gap * (1.6 + 5 + 0.8) with a label row, gap * (0.6 + 5 + 0.8) without.
    final gap = height / (label ? 7.4 : 6.4);
    return TabStaff(
      columns: [TabColumn.chord(chord, label: label)],
      columnWidth: gap * 2.2,
      lineGap: gap,
      fontSize: gap * 0.7,
    );
  }
}

/// Shows a chord the way the learner prefers (Me › Chord display): box diagram, tab, or both.
class ChordView extends StatelessWidget {
  const ChordView({super.key, required this.chord, this.width = 140, this.showName = true, this.display, this.compact = false});

  final Chord chord;

  /// Width of the box diagram; the tab is sized to match its height.
  final double width;
  final bool showName;

  /// Where there's only room for one picture, "both" falls back to the diagram.
  final bool compact;

  /// Overrides the learner's preference (e.g. the chord detail page always shows both).
  final ChordDisplay? display;

  @override
  Widget build(BuildContext context) {
    var mode = display ?? context.select<ProgressStore, ChordDisplay>((p) => p.chordDisplay);
    if (compact && mode == ChordDisplay.both) mode = ChordDisplay.diagram;
    final sideways = context.select<ProgressStore, bool>((p) => p.chordOrientation == ChordOrientation.sideways);
    final name = Text(chord.symbol, style: TextStyle(fontSize: width * 0.16, fontWeight: FontWeight.w800));
    final body = switch (mode) {
      ChordDisplay.diagram => ChordDiagram(chord: chord, width: width),
      ChordDisplay.tab => ChordTab(chord: chord, height: width * 1.2, label: false),
      // Sideways, the tab carries on the diagram's strings: the same line gap, tops aligned, and
      // the tab's string letters standing between the two.
      ChordDisplay.both when sideways => Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          ChordDiagram(chord: chord, width: width, stringNames: false),
          SizedBox(width: width * 0.04),
          ChordTab(
              chord: chord,
              height: ChordDiagram.heightFor(width, ChordOrientation.sideways) / SidewaysChordLayout.rows * 6.4,
              label: false),
        ]),
      ChordDisplay.both => Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
          ChordDiagram(chord: chord, width: width),
          SizedBox(width: width * 0.12),
          ChordTab(chord: chord, height: width * 1.2, label: false),
        ]),
    };
    if (!showName) return body;
    return Column(mainAxisSize: MainAxisSize.min, children: [name, const SizedBox(height: 4), body]);
  }
}
