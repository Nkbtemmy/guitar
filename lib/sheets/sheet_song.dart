import '../curriculum/models.dart';
import '../music/chord.dart';
import 'chord_resolver.dart';
import 'chord_sheet.dart';
import 'chord_symbol.dart';

/// A sheet as a practice chart for wait mode and play-along: every chord over a lyric is one
/// bar, in the shapes the learner plays ([shape] maps a written chord to its shown name).
Song sheetSong(ChordSheet sheet, {required String Function(String written) shape, required ChordResolver resolver}) {
  final lines = <SongLine>[];
  for (final l in sheet.lines) {
    if (l is! LyricLine) continue;
    final bars = [
      for (final c in l.chords)
        if (ChordSymbol.isChord(c.name) && resolver.resolve(shape(c.name)) != null) shape(c.name),
    ];
    if (bars.isNotEmpty) lines.add(SongLine(lyrics: l.text.trim(), bars: bars));
  }
  final beats = sheet.beatsPerBar.clamp(2, 6);
  return Song(
    id: 'sheet:${sheet.id}:${lines.expand((l) => l.bars).join(',').hashCode}',
    title: sheet.title,
    credit: sheet.artist.isEmpty ? 'Your song' : sheet.artist,
    bpm: sheet.tempo ?? 90,
    beatsPerBar: beats,
    pattern: switch (beats) {
      3 => 'D-DUDU',
      4 => 'D-DU-UDU',
      _ => 'D-' * beats,
    },
    lines: lines,
  );
}

/// The voicing [sheetSong]'s bars refer to.
Chord sheetChord(String name, ChordResolver resolver) => resolver.resolve(name)!;
