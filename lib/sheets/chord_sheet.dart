import 'chord_symbol.dart';
import 'tab_sequence.dart';

enum Difficulty {
  beginner('Beginner'),
  intermediate('Intermediate'),
  advanced('Advanced');

  const Difficulty(this.label);

  final String label;

  static Difficulty? parse(String? s) => s == null ? null : values.asNameMap()[s.trim().toLowerCase()];
}

/// A chord sitting over a lyric, at a character offset into it.
class ChordAt {
  const ChordAt(this.offset, this.name);

  final int offset;
  final String name;
}

sealed class SheetLine {
  const SheetLine();
}

/// "Verse 1", "Chorus".
class SectionLine extends SheetLine {
  const SectionLine(this.label);

  final String label;
}

/// A lyric with chords over it. [text] may be empty for a chords-only line (an intro).
class LyricLine extends SheetLine {
  const LyricLine(this.text, this.chords);

  final String text;
  final List<ChordAt> chords;
}

class CommentLine extends SheetLine {
  const CommentLine(this.text);

  final String text;
}

/// A block of text tab, kept as written; [sequence] is null when it isn't a full system.
class TabLines extends SheetLine {
  TabLines(this.lines, {this.label}) : sequence = TabSequence.parse(lines);

  final List<String> lines;
  final String? label;
  final TabSequence? sequence;
}

class BlankLine extends SheetLine {
  const BlankLine();
}

/// A song as chords over lyrics, with optional tab: what Ultimate Guitar calls a "chords" or
/// "tab" page. Read from ChordPro (`[C]Amazing [G]grace`) or from plain text with chords on
/// the line above the lyric, the way tabs are usually pasted.
class ChordSheet {
  const ChordSheet({
    required this.id,
    required this.title,
    this.artist = '',
    this.key,
    this.capo = 0,
    this.tempo,
    this.beatsPerBar = 4,
    this.difficulty,
    this.tags = const [],
    this.link,
    required this.lines,
  });

  final String id, title, artist;
  final String? key;

  /// The capo the chords are written for.
  final int capo;
  final int? tempo;
  final int beatsPerBar;
  final Difficulty? difficulty;
  final List<String> tags;

  /// A YouTube video of the song, to play while learning it.
  final String? link;
  final List<SheetLine> lines;

  /// Every chord name in order of first appearance.
  List<String> get chordNames {
    final seen = <String>{};
    return [
      for (final l in lines)
        for (final name in switch (l) {
          LyricLine(:final chords) => [for (final c in chords) c.name],
          // Chord names written over a tab.
          TabLines(:final sequence?) => sequence.labels.nonNulls,
          _ => const <String>[],
        })
          if (ChordSymbol.isChord(name) && seen.add(name)) name,
    ];
  }

  List<TabSequence> get tabs => [
        for (final l in lines)
          if (l is TabLines && l.sequence != null) l.sequence!,
      ];

  bool get hasTab => tabs.isNotEmpty;

  bool get hasLyrics => lines.any((l) => l is LyricLine && l.text.trim().isNotEmpty);

  /// Searchable text: title, artist and tags.
  String get searchText => '$title $artist ${tags.join(' ')} ${key ?? ''}'.toLowerCase();

  ChordSheet copyWith({String? id, String? title, String? artist, String? key, int? capo, int? tempo, String? link}) =>
      ChordSheet(
        id: id ?? this.id,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        key: key ?? this.key,
        capo: capo ?? this.capo,
        tempo: tempo ?? this.tempo,
        beatsPerBar: beatsPerBar,
        difficulty: difficulty,
        tags: tags,
        link: link ?? this.link,
        lines: lines,
      );

  /// Parses ChordPro or chords-over-lyrics text, whichever [source] looks like.
  factory ChordSheet.parse(String source, {required String id}) =>
      looksLikeChordPro(source) ? _ChordProReader(source, id).read() : _PlainReader(source, id).read();

  static final _inlineChord = RegExp(r'\[([^\]]+)\]');
  static final _directive = RegExp(r'^\s*\{\s*([\w-]+)\s*(?::\s*(.*?))?\s*\}\s*$');

  /// ChordPro has `{directives}` or chords inline in square brackets next to lyrics.
  static bool looksLikeChordPro(String source) {
    for (final line in source.split('\n')) {
      if (_directive.hasMatch(line)) return true;
      final chords = _inlineChord.allMatches(line).where((m) => _isChordToken(m.group(1)!)).toList();
      if (chords.isNotEmpty && line.replaceAll(_inlineChord, '').trim().isNotEmpty) return true;
    }
    return false;
  }

  /// Writes the sheet as ChordPro, the format most chord apps import. Without [meta], only
  /// the song body (no title, key... directives).
  String toChordPro({bool meta = true}) {
    final out = StringBuffer();
    void directive(String k, Object? v) {
      if (v != null && '$v'.isNotEmpty) out.writeln('{$k: $v}');
    }

    if (meta) {
      directive('title', title);
      directive('artist', artist);
      directive('key', key);
      if (capo > 0) directive('capo', capo);
      directive('tempo', tempo);
      if (beatsPerBar != 4) directive('time', '$beatsPerBar/4');
      directive('difficulty', difficulty?.name);
      if (tags.isNotEmpty) directive('tags', tags.join(', '));
      directive('youtube', link);
      out.writeln();
    }
    for (final l in lines) {
      switch (l) {
        case SectionLine(:final label):
          out.writeln('{comment: $label}');
        case LyricLine(:final text, :final chords):
          out.writeln(inlineChords(text, chords));
        case CommentLine(:final text):
          out.writeln('{comment: $text}');
        case TabLines(:final lines, :final label):
          out.writeln(label == null ? '{start_of_tab}' : '{start_of_tab: $label}');
          lines.forEach(out.writeln);
          out.writeln('{end_of_tab}');
        case BlankLine():
          out.writeln();
      }
    }
    return out.toString().trimRight();
  }

  /// "[C]Amazing [G]grace", padding the lyric when a chord sits past its end.
  static String inlineChords(String text, List<ChordAt> chords) {
    final sorted = [...chords]..sort((a, b) => a.offset.compareTo(b.offset));
    final out = StringBuffer();
    var pos = 0;
    for (final c in sorted) {
      if (c.offset > pos) {
        final end = c.offset.clamp(0, text.length);
        out.write(text.substring(pos.clamp(0, text.length), end));
        if (c.offset > text.length) out.write(' ' * (c.offset - (pos > text.length ? pos : text.length)));
        pos = c.offset;
      }
      out.write('[${c.name}]');
    }
    if (pos < text.length) out.write(text.substring(pos));
    return out.toString();
  }
}

/// Words that may sit on a chord line without being chords: bar lines, repeat marks, "N.C.".
bool _isDecoration(String t) =>
    RegExp(r'^(\||\|\||-+|/+|%|\.+|\(?x\d+\)?|\d+x|\(|\)|N\.?C\.?|riff|\*)$', caseSensitive: false).hasMatch(t);

bool _isChordToken(String t) => ChordSymbol.isChord(t.replaceAll(RegExp(r'^\(|\)$|\*$'), ''));

/// "[Verse 1]", "Chorus:", "INTRO" on a line of its own.
String? _sectionLabel(String line) {
  final t = line.trim();
  final bracket = RegExp(r'^\[([^\]]+)\]$').firstMatch(t);
  if (bracket != null && !_isChordToken(bracket.group(1)!)) return bracket.group(1)!.trim();
  final named = RegExp(
    r'^(intro|verse|chorus|pre-chorus|prechorus|bridge|outro|solo|interlude|instrumental|refrain|coda|ending|riff|tag)(\s*\d+)?\s*:?$',
    caseSensitive: false,
  ).firstMatch(t);
  if (named != null) {
    final word = named.group(1)!;
    return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}${named.group(2) ?? ''}'.trim();
  }
  return null;
}

/// Chords at their columns if [line] holds only chords (and bar lines or repeat marks).
List<ChordAt>? _chordLine(String line) {
  final tokens = RegExp(r'\S+').allMatches(line).toList();
  if (tokens.isEmpty) return null;
  final chords = <ChordAt>[];
  for (final m in tokens) {
    final t = m.group(0)!;
    if (_isChordToken(t)) {
      chords.add(ChordAt(m.start, t.replaceAll(RegExp(r'^\(|\)$|\*$'), '')));
    } else if (!_isDecoration(t)) {
      return null;
    }
  }
  return chords.isEmpty ? null : chords;
}

/// Groups six or more consecutive tab lines starting at [i]; returns how many lines it took.
int _tabRun(List<String> lines, int i) {
  var j = i;
  while (j < lines.length && TabSequence.isTabLine(lines[j])) {
    j++;
  }
  return j - i >= 6 ? j - i : 0;
}

/// Like [_tabRun], but also takes a line of chord names sitting right above the tab.
int _tabBlock(List<String> lines, int i) {
  if (i + 1 < lines.length && TabSequence.isChordLine(lines[i])) {
    final run = _tabRun(lines, i + 1);
    if (run > 0) return run + 1;
  }
  return _tabRun(lines, i);
}

class _Meta {
  String title = '', artist = '';
  String? key;
  int capo = 0, beatsPerBar = 4;
  int? tempo;
  Difficulty? difficulty;
  List<String> tags = const [];
  String? link;

  /// Applies a metadata directive; false when [name] isn't one.
  bool apply(String name, String value) {
    switch (name) {
      case 'title' || 't':
        title = value;
      case 'artist' || 'subtitle' || 'st' || 'composer':
        if (artist.isEmpty) artist = value;
      case 'key':
        key = value;
      case 'capo':
        capo = _wholeIn(value, 0, 12) ?? 0;
      case 'tempo':
        tempo = _wholeIn(value, 30, 300);
      case 'time':
        beatsPerBar = _wholeIn(value.split('/').first, 1, 12) ?? 4;
      case 'difficulty' || 'x_difficulty':
        difficulty = Difficulty.parse(value);
      case 'tags' || 'x_tags':
        tags = [
          for (final t in value.split(','))
            if (t.trim().isNotEmpty) t.trim(),
        ];
      case 'youtube' || 'x_youtube' || 'link':
        link = youtubeUrl(value);
      default:
        return false;
    }
    return true;
  }

  ChordSheet build(String id, List<SheetLine> lines) {
    // Drop leading, trailing and repeated blank lines.
    final tidy = <SheetLine>[];
    for (final l in lines) {
      if (l is BlankLine && (tidy.isEmpty || tidy.last is BlankLine)) continue;
      tidy.add(l);
    }
    while (tidy.isNotEmpty && tidy.last is BlankLine) {
      tidy.removeLast();
    }
    return ChordSheet(
      id: id,
      title: title.isEmpty ? 'Untitled' : title,
      artist: artist,
      key: key,
      capo: capo,
      tempo: tempo,
      beatsPerBar: beatsPerBar,
      difficulty: difficulty,
      tags: tags,
      link: link,
      lines: tidy,
    );
  }
}

class _ChordProReader {
  _ChordProReader(String source, this.id) : lines = source.replaceAll('\r', '').split('\n');

  final String id;
  final List<String> lines;
  final meta = _Meta();
  final out = <SheetLine>[];

  /// The last chorus, replayed by `{chorus}`; null when not inside one.
  List<SheetLine> _chorus = const [];
  List<SheetLine>? _capturing;

  void _add(SheetLine l) {
    out.add(l);
    _capturing?.add(l);
  }

  void _endChorus() {
    if (_capturing != null) _chorus = _capturing!;
    _capturing = null;
  }

  ChordSheet read() {
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('#')) continue;
      // A chorus runs to {end_of_chorus}, or to the first blank line when that's missing.
      if (line.trim().isEmpty) _endChorus();
      final d = ChordSheet._directive.firstMatch(line);
      if (d != null) {
        i = _directive(d.group(1)!.toLowerCase(), d.group(2)?.trim() ?? '', i);
        continue;
      }
      final run = _tabBlock(lines, i);
      if (run > 0) {
        _add(TabLines(lines.sublist(i, i + run)));
        i += run - 1;
        continue;
      }
      _add(_lyric(line));
    }
    return meta.build(id, out);
  }

  /// Handles a directive on line [i]; returns the index of the last line it used.
  int _directive(String name, String value, int i) {
    if (meta.apply(name, value)) return i;
    switch (name) {
      case 'comment' || 'c' || 'comment_italic' || 'ci' || 'comment_box' || 'cb' || 'highlight':
        _add(_sectionLabel(value) != null ? SectionLine(_sectionLabel(value)!) : CommentLine(value));
      case 'start_of_chorus' || 'soc':
        _endChorus();
        out.add(SectionLine(value.isEmpty ? 'Chorus' : value));
        _capturing = [];
      case 'end_of_chorus' || 'eoc':
        _endChorus();
      case 'start_of_verse' || 'sov':
        _endChorus();
        out.add(SectionLine(value.isEmpty ? 'Verse' : value));
      case 'start_of_bridge' || 'sob':
        _endChorus();
        out.add(SectionLine(value.isEmpty ? 'Bridge' : value));
      case 'chorus':
        _endChorus();
        out.add(SectionLine(value.isEmpty ? 'Chorus' : value));
        out.addAll(_chorus);
      case 'start_of_tab' || 'sot':
        _endChorus();
        final body = <String>[];
        var j = i + 1;
        for (; j < lines.length; j++) {
          final end = ChordSheet._directive.firstMatch(lines[j]);
          if (end != null && const {'end_of_tab', 'eot'}.contains(end.group(1)!.toLowerCase())) break;
          body.add(lines[j]);
        }
        _add(TabLines(body, label: value.isEmpty ? null : value));
        return j;
    }
    return i;
  }

  SheetLine _lyric(String line) {
    if (line.trim().isEmpty) return const BlankLine();
    final label = _sectionLabel(line);
    if (label != null) return SectionLine(label);
    final text = StringBuffer();
    final chords = <ChordAt>[];
    var pos = 0;
    for (final m in ChordSheet._inlineChord.allMatches(line)) {
      text.write(line.substring(pos, m.start));
      chords.add(ChordAt(text.length, m.group(1)!.trim()));
      pos = m.end;
    }
    text.write(line.substring(pos));
    return LyricLine(text.toString().trimRight(), chords);
  }
}

class _PlainReader {
  _PlainReader(String source, this.id) : lines = source.replaceAll('\r', '').replaceAll('\t', '    ').split('\n');

  final String id;
  final List<String> lines;

  ChordSheet read() {
    final meta = _Meta();
    final out = <SheetLine>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) {
        out.add(const BlankLine());
        continue;
      }
      final run = _tabBlock(lines, i);
      if (run > 0) {
        out.add(TabLines(lines.sublist(i, i + run)));
        i += run - 1;
        continue;
      }
      final label = _sectionLabel(line);
      if (label != null) {
        out.add(SectionLine(label));
        continue;
      }
      final chords = _chordLine(line);
      if (chords == null) {
        out.add(LyricLine(line.trimRight(), const []));
        continue;
      }
      // A chord line pairs with the lyric right under it.
      final next = i + 1 < lines.length ? lines[i + 1] : '';
      final pairs = next.trim().isNotEmpty &&
          _chordLine(next) == null &&
          _sectionLabel(next) == null &&
          !TabSequence.isTabLine(next);
      if (pairs) {
        out.add(LyricLine(next.trimRight(), chords));
        i++;
      } else {
        out.add(LyricLine('', chords));
      }
    }
    return meta.build(id, out);
  }
}

/// [text] as a whole number from [min] to [max], else null. Sheets are user text: without the
/// range, {tempo: 0} or {time: 0/4} reach the audio code as a division by zero, and {tempo: 1}
/// as a gigabyte audio buffer.
int? _wholeIn(String text, int min, int max) {
  final v = int.tryParse(text.trim());
  return v != null && v >= min && v <= max ? v : null;
}

/// A YouTube watch link for [text] (watch, youtu.be, shorts, music or mobile links), or null
/// when it isn't one.
String? youtubeUrl(String text) {
  final t = text.trim();
  final u = Uri.tryParse(t.contains('://') ? t : 'https://$t');
  if (u == null) return null;
  final host = u.host.replaceFirst(RegExp(r'^(www|m|music)\.'), '');
  String? id;
  // Reading the path or query decodes %xx escapes, which throws on bad ones ("youtu.be/%FF").
  try {
    if (host == 'youtu.be') {
      id = u.pathSegments.firstOrNull;
    } else if (host == 'youtube.com') {
      id = u.queryParameters['v'];
      if (id == null && u.pathSegments.length >= 2 && const {'shorts', 'embed', 'live'}.contains(u.pathSegments[0])) {
        id = u.pathSegments[1];
      }
    }
  } on FormatException {
    return null;
  }
  if (id == null || !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) return null;
  return 'https://www.youtube.com/watch?v=$id';
}
