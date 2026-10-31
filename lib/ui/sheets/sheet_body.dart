import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../music/chord.dart';
import '../../progress/practice_log.dart';
import '../../sheets/chord_resolver.dart';
import '../../sheets/chord_sheet.dart';
import '../../sheets/chord_symbol.dart';
import '../chords/chords_screen.dart';
import '../lesson/steps.dart';
import '../theme.dart';
import '../widgets/chord_view.dart';
import '../widgets/tab_staff.dart';
import 'tab_player.dart';

/// How a sheet is shown: shifted chords, the capo the learner uses, simplified shapes.
class SheetDisplay {
  const SheetDisplay({this.shift = 0, this.capo = 0, this.simplify = false, this.fontScale = 1.0});

  /// Semitones every written chord moves by to give the shape the learner plays.
  final int shift;

  /// The capo the learner plays with (for sounding pitch).
  final int capo;
  final bool simplify;
  final double fontScale;

  /// The shape name shown for a written chord.
  String label(String written, ChordResolver resolver) {
    final shape = transposeName(written, shift);
    if (!simplify) return shape;
    return resolver.resolve(shape, simplify: true)?.symbol ?? shape;
  }

  Chord? voicing(String written, ChordResolver resolver) =>
      resolver.resolve(transposeName(written, shift), simplify: simplify);
}

/// Opens tab [index] of [sheet] (counting its tab blocks) in the player. With [from] and [to]
/// it opens on those notes, looping them (practising a weak spot).
void openTabPlayer(BuildContext context, ChordSheet sheet, int index, {int? from, int? to}) {
  final blocks = sheet.lines.whereType<TabLines>().toList();
  final seq = index < blocks.length ? blocks[index].sequence : null;
  if (seq == null) return;
  final label = blocks[index].label;
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => TabPlayerScreen(
      tab: seq,
      title: label == null ? sheet.title : '${sheet.title} · $label',
      bpm: sheet.tempo ?? 90,
      beatsPerBar: sheet.beatsPerBar,
      // The tab's text is in the key, so an edited song doesn't replay its old audio.
      id: '${sheet.id}#$index:${Object.hashAll(blocks[index].lines)}',
      place: SpotPlace.tab(sheet.id, index),
      from: from,
      to: to,
    ),
  ));
}

/// The lines of a sheet: section labels, chords over lyrics (tap a chord for its diagram), and
/// tab blocks with a play button.
class SheetBody extends StatelessWidget {
  const SheetBody({super.key, required this.sheet, this.display = const SheetDisplay()});

  final ChordSheet sheet;
  final SheetDisplay display;

  @override
  Widget build(BuildContext context) {
    final resolver = context.read<AppServices>().resolver;
    final scale = display.fontScale;
    var tabIndex = 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in sheet.lines)
          switch (line) {
            SectionLine(:final label) => Padding(
                padding: EdgeInsets.only(top: 14 * scale, bottom: 4),
                child: Text(
                  label,
                  style:
                      TextStyle(fontSize: 14 * scale, fontWeight: FontWeight.w800, color: kMuted, letterSpacing: 0.4),
                ),
              ),
            LyricLine(:final text, :final chords) => _LyricLineView(
                text: text,
                chords: [for (final c in chords) ChordAt(c.offset, display.label(c.name, resolver))],
                written: [for (final c in chords) c.name],
                scale: scale,
                onChord: (written) => showChordSheet(context, written, display),
              ),
            CommentLine(:final text) => Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(10)),
                child: Text(
                  text,
                  style: TextStyle(fontStyle: FontStyle.italic, fontSize: 14 * scale, color: kTextSoft),
                ),
              ),
            TabLines() => _TabBlock(block: line, sheet: sheet, index: tabIndex++, scale: scale),
            BlankLine() => SizedBox(height: 12 * scale),
          },
      ],
    );
  }
}

/// Opens the diagram for a written chord, as the learner would play it.
void showChordSheet(BuildContext context, String written, SheetDisplay display) {
  final services = context.read<AppServices>();
  final chord = display.voicing(written, services.resolver);
  if (chord == null) return;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(chord.symbol, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
            if (display.capo > 0)
              Text(
                'Shape with capo ${display.capo} (sounds as ${transposeName(chord.symbol, display.capo)})',
                style: const TextStyle(color: kMuted),
              ),
            const SizedBox(height: 12),
            ChordView(chord: chord, width: 130, showName: false),
            const SizedBox(height: 12),
            for (final line in chord.placement) Text(line, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 8,
              children: [
                HearButton(onPressed: () => services.player.playChord(chord.withCapo(display.capo))),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => ChordDetailScreen(chord: chord))),
                  icon: const Icon(Icons.mic_rounded),
                  label: const Text('Check my chord'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// One lyric line with its chords on top. Words wrap as units, and a chord wider than its
/// syllable pushes the lyric apart rather than overlapping the next chord.
class _LyricLineView extends StatelessWidget {
  const _LyricLineView({
    required this.text,
    required this.chords,
    required this.written,
    required this.scale,
    required this.onChord,
  });

  final String text;
  final List<ChordAt> chords;

  /// Chord names as written, parallel to [chords], for opening diagrams.
  final List<String> written;
  final double scale;
  final ValueChanged<String> onChord;

  @override
  Widget build(BuildContext context) {
    final chordStyle = TextStyle(fontSize: 15 * scale, fontWeight: FontWeight.w800, color: kAccent, height: 1.3);
    final lyricStyle = TextStyle(fontSize: 16 * scale, color: kText, height: 1.35);
    if (chords.isEmpty) return Text(text, style: lyricStyle);

    final at = <int, List<int>>{};
    for (var i = 0; i < chords.length; i++) {
      (at[chords[i].offset] ??= []).add(i);
    }
    // A chords-only line has no lyric units; its chords all go in the trailing loop below.
    final breaks = <int>{if (text.isNotEmpty) 0, ...at.keys.where((o) => o < text.length)};
    for (var i = 1; i < text.length; i++) {
      if (text[i] != ' ' && text[i - 1] == ' ') breaks.add(i);
    }
    final starts = breaks.toList()..sort();
    final units = <Widget>[];
    Widget unit(String lyric, List<int>? chordIdx) => Padding(
          padding: EdgeInsets.only(right: chordIdx != null && lyric.trim().isEmpty ? 12 * scale : 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (chordIdx == null)
                Text(' ', style: chordStyle)
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final i in chordIdx)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onChord(written[i]),
                        child: Padding(
                          padding: EdgeInsets.only(right: 6 * scale),
                          child: Text(chords[i].name, style: chordStyle),
                        ),
                      ),
                  ],
                ),
              if (text.isNotEmpty) Text(lyric.replaceAll(' ', ' '), style: lyricStyle),
            ],
          ),
        );
    for (var k = 0; k < starts.length; k++) {
      final start = starts[k];
      final end = k + 1 < starts.length ? starts[k + 1] : text.length;
      units.add(unit(text.substring(start, end), at[start]));
    }
    // Chords past the end of the lyric (or on a chords-only line).
    final trailing = at.keys.where((o) => o >= text.length).toList()..sort();
    for (final o in trailing) {
      units.add(unit('', at[o]));
    }
    return Padding(
      padding: EdgeInsets.only(bottom: 4 * scale),
      child: Wrap(children: units),
    );
  }
}

class _TabBlock extends StatelessWidget {
  const _TabBlock({required this.block, required this.sheet, required this.index, required this.scale});

  final TabLines block;
  final ChordSheet sheet;
  final int index;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final seq = block.sequence;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (block.label != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 4),
                  child: Text(
                    block.label!,
                    style: const TextStyle(fontWeight: FontWeight.w800, color: kMuted),
                  ),
                ),
              if (seq == null)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    block.lines.join('\n'),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontFamilyFallback: const ['Courier'],
                      fontSize: 13 * scale,
                    ),
                  ),
                )
              else ...[
                TabStaff(
                  columns: [for (var i = 0; i < seq.events.length; i++) TabColumn(seq.events[i].frets, label: seq.labels[i])],
                  bars: seq.barStarts,
                  columnWidth: 26 * scale,
                  lineGap: 14 * scale,
                  fontSize: 12 * scale,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => openTabPlayer(context, sheet, index),
                    icon: const Icon(Icons.play_circle_rounded),
                    label: const Text('Play tab'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
