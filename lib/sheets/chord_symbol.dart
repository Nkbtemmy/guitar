/// Chord names as written in song sheets ("C", "F#m7", "Bb/D"), and transposing them.
library;

const _sharpNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const _flatNames = ['C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B'];

/// How roots are most often spelled after transposing: Bb, Eb and Ab rather than A#, D#, G#,
/// but F# and C# rather than Gb and Db. Minor chords on G# keep the sharp (G#m, not Abm).
String commonRootName(int pitchClass, {bool minor = false}) {
  final pc = pitchClass % 12;
  if (minor && (pc == 8 || pc == 3)) return _sharpNames[pc];
  return const ['C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B'][pc];
}

int? _pitchClassOf(String letter, String accidental) {
  const naturals = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};
  final base = naturals[letter];
  if (base == null) return null;
  return (base +
          (accidental == '#'
              ? 1
              : accidental == 'b'
                  ? -1
                  : 0)) %
      12;
}

/// The chord families Guitaro can voice. Anything richer is voiced as its nearest family.
enum ChordQuality {
  major(''),
  minor('m'),
  dom7('7'),
  maj7('maj7'),
  min7('m7'),
  sus2('sus2'),
  sus4('sus4'),
  dom7sus4('7sus4'),
  add9('add9'),
  dom9('9'),
  six('6'),
  min6('m6'),
  power('5'),
  dim('dim'),
  dim7('dim7'),
  halfDim('m7b5'),
  aug('aug');

  const ChordQuality(this.suffix);

  /// Canonical suffix, matching the chord library's symbols.
  final String suffix;

  bool get isMinor => this == minor || this == min7 || this == min6 || this == halfDim || this == dim || this == dim7;

  /// The plain triad (or power chord) underneath, for "simplify".
  ChordQuality get triad => switch (this) {
        minor || min7 || min6 => minor,
        dim || dim7 || halfDim => dim,
        aug => aug,
        power => power,
        _ => major,
      };

  static ChordQuality? fromSuffix(String s) {
    final t = s.replaceAll('(', '').replaceAll(')', '');
    return switch (t) {
      '' || 'M' || 'maj' => major,
      'm' || 'min' || '-' || 'mi' => minor,
      '7' || 'dom7' => dom7,
      'maj7' || 'M7' || 'Maj7' || 'ma7' || 'Δ' || 'Δ7' => maj7,
      'm7' || 'min7' || '-7' || 'mi7' => min7,
      'sus2' || '2' => sus2,
      'sus4' || 'sus' || '4' => sus4,
      '7sus4' || '7sus' => dom7sus4,
      'add9' || 'add2' => add9,
      '9' || '11' || '13' || '7b9' || '7#9' => dom9,
      '6' || '69' || '6/9' => six,
      'm6' || 'min6' => min6,
      '5' => power,
      'dim' || '°' || 'o' => dim,
      'dim7' || '°7' || 'o7' => dim7,
      'm7b5' || 'ø' || 'ø7' || 'min7b5' => halfDim,
      'aug' || '+' || '+5' || '#5' => aug,
      'maj9' || 'M9' || 'maj13' => maj7,
      'm9' || 'm11' || 'min9' => min7,
      'madd9' => minor,
      _ => null,
    };
  }
}

/// A chord name split into root, quality and optional bass note.
class ChordSymbol {
  const ChordSymbol({required this.root, required this.quality, required this.suffix, this.bass, this.flats = false});

  /// Pitch class of the root, 0 = C.
  final int root;
  final ChordQuality quality;

  /// The suffix exactly as written ("min7", "maj9"...), kept for display.
  final String suffix;
  final int? bass;

  /// Whether the original spelling used flats (kept when transposing would be ambiguous).
  final bool flats;

  static final _pattern = RegExp(r'^([A-G])([#b]?)([^/\s]*)(?:/([A-G])([#b]?))?$');

  /// Parses a chord name, or returns null when [text] isn't one (a lyric word, "x2", "|").
  static ChordSymbol? tryParse(String text) {
    final m = _pattern.firstMatch(text.trim());
    if (m == null) return null;
    final suffix = m.group(3)!;
    final quality = ChordQuality.fromSuffix(suffix);
    if (quality == null) return null;
    final bass = m.group(4) == null ? null : _pitchClassOf(m.group(4)!, m.group(5)!);
    return ChordSymbol(
      root: _pitchClassOf(m.group(1)!, m.group(2)!)!,
      quality: quality,
      suffix: suffix,
      bass: bass,
      flats: m.group(2) == 'b' || m.group(5) == 'b',
    );
  }

  static bool isChord(String text) => tryParse(text) != null;

  /// Shifted by [semitones]. Roots are spelled the common way ([commonRootName]).
  ChordSymbol transpose(int semitones) {
    if (semitones % 12 == 0) return this;
    return ChordSymbol(
      root: (root + semitones) % 12,
      quality: quality,
      suffix: suffix,
      bass: bass == null ? null : (bass! + semitones) % 12,
    );
  }

  String get rootName => flats ? _flatNames[root] : commonRootName(root, minor: quality.isMinor);

  /// The bass note follows the root's accidentals; after a natural root, sharp keys (G, D,
  /// A, E, B) take sharps and C and F take flats: E/G#, D/F#, C/Bb.
  String get bassName {
    if (bass == null) return '';
    final r = rootName;
    final sharps = r.contains('#') || (!r.contains('b') && !flats && !{'C', 'F'}.contains(r));
    return (sharps ? _sharpNames : _flatNames)[bass!];
  }

  /// The written name, e.g. "Bb/D".
  String get name => '$rootName$suffix${bass == null ? '' : '/$bassName'}';

  /// Root plus canonical suffix, without the bass note: the key the chord library is searched by.
  String get canonical => '${commonRootName(root, minor: quality.isMinor)}${quality.suffix}';

  @override
  String toString() => name;
}

/// Transposes a chord name, leaving anything that isn't a chord untouched.
String transposeName(String text, int semitones) {
  if (semitones % 12 == 0) return text;
  return ChordSymbol.tryParse(text)?.transpose(semitones).name ?? text;
}

/// Transposes a key name such as "G" or "Em".
String transposeKey(String key, int semitones) => transposeName(key, semitones);
