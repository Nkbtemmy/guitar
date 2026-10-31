import '../music/notes.dart';
import 'chord_symbol.dart';

/// A moment in a tab where one or more strings are picked.
class TabEvent {
  const TabEvent(this.column, this.frets);

  /// Position in sixteenths from the start of the tab: the spacing is the rhythm.
  final int column;

  /// String number (1 = high e .. 6 = low E) to fret.
  final Map<int, int> frets;

  List<int> get midiNotes => [for (final e in frets.entries) midiAt(e.key, e.value)]..sort();
}

/// Plain-text guitar tab ("e|--0--3--|") read as notes in time.
///
/// Text tab carries no rhythm marks, so the spacing does: each character column is a
/// sixteenth note, except bar lines, which take no time. A quarter note is a number followed
/// by three dashes. Systems stacked
/// one under another play one after the other. A line of chord names right above a system
/// labels the notes under each name.
class TabSequence {
  TabSequence(this.events, {required this.length, this.bars = const [], this.chords = const {}});

  final List<TabEvent> events;

  /// Total length in sixteenths (columns), including trailing dashes.
  final int length;

  /// Where each bar line falls, in columns: the start of the bar after it.
  final List<int> bars;

  /// Chord names by the column they're written over.
  final Map<int, String> chords;

  /// The chord name over each event, or null; a name written between two notes goes on the next.
  late final List<String?> labels = [
    for (var i = 0; i < events.length; i++) _chordIn(i == 0 ? -1 : events[i - 1].column, events[i].column),
  ];

  /// Indexes of the events that start a new bar (after a bar line, not counting the first).
  late final List<int> barStarts = [
    for (var i = 1; i < events.length; i++)
      if (bars.any((b) => b > events[i - 1].column && b <= events[i].column)) i,
  ];

  /// The last chord written over columns after..upTo (exclusive, inclusive).
  String? _chordIn(int after, int upTo) {
    final hits = chords.keys.where((c) => c > after && c <= upTo).toList()..sort();
    return hits.isEmpty ? null : chords[hits.last];
  }

  static const columnsPerBeat = 4;

  static final _prefix = RegExp(r'^\s*([A-Ga-g][#b]?)?\s*([|:])');
  static final _body = RegExp(r'^[-0-9|:hpbrx/\\~^().*sSvtPHBRL=<> ]*$');

  /// Whether [line] looks like one string of a tab ("e|-0-1-", "B|--3--|").
  static bool isTabLine(String line) {
    final m = _prefix.firstMatch(line);
    final rest = m == null ? line.trim() : line.substring(m.end);
    // Without an "e|" prefix, a row of dashes is just a separator unless it holds a fret.
    if ('-'.allMatches(rest).length < (m == null ? 4 : 2)) return false;
    if (m == null && !rest.contains(RegExp(r'\d'))) return false;
    return _body.hasMatch(rest);
  }

  /// Reads [lines] (one or more six-line systems, high e on top). Returns null when there
  /// isn't a complete system.
  static TabSequence? parse(List<String> lines) {
    final strings = <String>[];
    // The chord line sitting right above each string line, if any.
    final above = <String?>[];
    for (var i = 0; i < lines.length; i++) {
      if (!isTabLine(lines[i])) continue;
      strings.add(lines[i]);
      above.add(i > 0 && isChordLine(lines[i - 1]) ? lines[i - 1] : null);
    }
    if (strings.length < 6) return null;
    final events = <TabEvent>[];
    final bars = <int>[];
    final chords = <int, String>{};
    var offset = 0;
    for (var s = 0; s + 6 <= strings.length; s += 6) {
      final bodies = [for (final l in strings.sublist(s, s + 6)) _stripPrefix(l)];
      final chordLine = above[s];
      final width = bodies.map((b) => b.length).reduce((a, b) => a > b ? a : b);
      // Bar lines (and repeat dots) mark the bars but take no time: each other character is a
      // sixteenth. time[c] is how many sixteenths come before character c.
      final time = List<int>.filled(width + 1, 0);
      for (var c = 0, t = 0; c <= width; c++) {
        time[c] = t;
        if (c == width) break;
        final mark = c < bodies[0].length && (bodies[0][c] == '|' || bodies[0][c] == ':');
        if (mark) {
          if (bodies[0][c] == '|') bars.add(offset + t);
        } else {
          t++;
        }
      }
      if (chordLine != null) {
        // Line the names up with the tab body, past the "e|" prefix.
        final indent = strings[s].length - bodies[0].length;
        for (final m in RegExp(r'\S+').allMatches(chordLine)) {
          if (ChordSymbol.isChord(m.group(0)!)) chords[offset + time[(m.start - indent).clamp(0, width)]] = m.group(0)!;
        }
      }
      final byColumn = <int, Map<int, int>>{};
      for (var i = 0; i < 6; i++) {
        final body = bodies[i];
        for (var c = 0; c < body.length; c++) {
          final d = _digit(body, c);
          if (d == null) continue;
          var fret = d;
          final two = _digit(body, c + 1);
          if (two != null && fret * 10 + two <= 24) {
            fret = fret * 10 + two;
          }
          (byColumn[offset + time[c]] ??= {})[i + 1] = fret;
          if (fret >= 10) c++;
        }
      }
      final columns = byColumn.keys.toList()..sort();
      events.addAll([for (final c in columns) TabEvent(c, byColumn[c]!)]);
      offset += time[width];
    }
    if (events.isEmpty) return null;
    return TabSequence(events, length: offset, bars: bars, chords: chords);
  }

  /// Whether [line] holds only chord names (and bar lines), as written above a tab.
  static bool isChordLine(String line) {
    final tokens = RegExp(r'\S+').allMatches(line).map((m) => m.group(0)!).toList();
    return tokens.any(ChordSymbol.isChord) &&
        tokens.every((t) => ChordSymbol.isChord(t) || RegExp(r'^[|:]+$').hasMatch(t));
  }

  static String _stripPrefix(String line) {
    final m = _prefix.firstMatch(line);
    return m == null ? line.trim() : line.substring(m.end);
  }

  static int? _digit(String s, int i) {
    if (i >= s.length) return null;
    final c = s.codeUnitAt(i) - 48;
    return c >= 0 && c <= 9 ? c : null;
  }

  /// Seconds per column at [bpm].
  static double columnSeconds(int bpm) => 60 / bpm / columnsPerBeat;

  /// Time of event [i] from the start of the passage that begins at event [from].
  double timeOf(int i, int bpm, {int from = 0}) => (events[i].column - events[from].column) * columnSeconds(bpm);

  /// Length of events [from]..[to] (inclusive) in seconds, ending one beat after the last note.
  double durationOf(int bpm, {int from = 0, int? to}) {
    final last = to ?? events.length - 1;
    return timeOf(last, bpm, from: from) + 60 / bpm;
  }

  /// Index of the event sounding at [seconds] into a passage starting at [from], or -1 before it.
  int eventAt(double seconds, int bpm, {int from = 0, int? to}) {
    final last = to ?? events.length - 1;
    var found = -1;
    for (var i = from; i <= last; i++) {
      if (timeOf(i, bpm, from: from) <= seconds + 1e-6) {
        found = i;
      } else {
        break;
      }
    }
    return found;
  }
}
