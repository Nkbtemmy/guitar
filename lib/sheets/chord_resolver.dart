import '../music/chord.dart';
import '../music/chord_library.dart';
import '../music/notes.dart';
import 'chord_symbol.dart';

/// Turns any chord name into a playable voicing. The hand-written library comes first; any
/// other chord gets a movable E-shape or A-shape barre (or a power chord), so every chord in
/// a sheet has a diagram and a sound.
class ChordResolver {
  ChordResolver(this.library) {
    for (final c in library.chords) {
      final s = ChordSymbol.tryParse(c.symbol);
      if (s == null) continue;
      (_byName[s.canonical] ??= []).add(c);
    }
    // Easiest first; equally easy shapes keep library order (G before G_easy).
    final order = {for (var i = 0; i < library.chords.length; i++) library.chords[i].id: i};
    for (final list in _byName.values) {
      list.sort((a, b) {
        final d = difficulty(a).compareTo(difficulty(b));
        return d != 0 ? d : order[a.id]!.compareTo(order[b.id]!);
      });
    }
  }

  final ChordLibrary library;
  final _byName = <String, List<Chord>>{};
  final _cache = <String, Chord?>{};

  /// Rough effort to play a voicing: open shapes 1, sevenths and colour chords a bit more,
  /// power chords 2, barre chords 3.
  static double difficulty(Chord c) => switch (c.category) {
        'open' || 'easy' => 1,
        'seventh' || 'color' => 1.2,
        'power' => 2,
        _ => c.barre != null ? 3 : 2.5,
      };

  /// The voicing for [name], or null when it isn't a chord. With [simplify], extensions are
  /// dropped (Am7 → Am, Cmaj7 → C) and the easiest shape that still holds the triad is used
  /// (F → Fmaj7, B → B7).
  Chord? resolve(String name, {bool simplify = false}) => _cache.putIfAbsent('$name|$simplify', () {
        final s = ChordSymbol.tryParse(name);
        if (s == null) return null;
        return simplify ? _simplest(s) : _voicing(s);
      });

  Chord? _voicing(ChordSymbol s) {
    final exact = _byName[s.canonical];
    if (exact != null) return exact.first;
    return generate(s.root, s.quality) ?? _voicingFallback(s);
  }

  Chord? _voicingFallback(ChordSymbol s) {
    final triad = s.quality.triad;
    if (triad == s.quality) return null;
    return _voicing(ChordSymbol(root: s.root, quality: triad, suffix: triad.suffix));
  }

  Chord? _simplest(ChordSymbol s) {
    final triad = ChordSymbol(root: s.root, quality: s.quality.triad, suffix: s.quality.triad.suffix);
    final base = _voicing(triad);
    if (base == null) return null;
    if (difficulty(base) < 3) return base;
    // An easier library shape on the same root that contains every note of the triad.
    final want = base.pitchClasses;
    Chord? best;
    for (final c in library.chords) {
      if (c.category == 'barre' || c.category == 'power') continue;
      final cs = ChordSymbol.tryParse(c.symbol);
      if (cs == null || cs.root != s.root) continue;
      if (!c.pitchClasses.containsAll(want)) continue;
      if (best == null || difficulty(c) < difficulty(best)) best = c;
    }
    return best ?? base;
  }

  /// Total effort to play [names] (each counted once), used to suggest a capo.
  double effort(Iterable<String> names, {bool simplify = false}) {
    var total = 0.0;
    for (final n in names.toSet()) {
      final c = resolve(n, simplify: simplify);
      total += c == null ? 0 : difficulty(c);
    }
    return total;
  }

  /// The capo position (0..7) whose shapes are easiest for chords that sound as [sounding].
  /// Ties go to the lower fret. Returns 0 when no capo helps.
  int suggestCapo(Iterable<String> sounding, {bool simplify = false}) {
    final names = sounding.toSet();
    var best = 0;
    var bestEffort = effort(names, simplify: simplify);
    for (var capo = 1; capo <= 7; capo++) {
      final e = effort(names.map((n) => transposeName(n, -capo)), simplify: simplify);
      // Only move the capo for a clear gain.
      if (e < bestEffort - 0.5) {
        best = capo;
        bestEffort = e;
      }
    }
    return best;
  }

  /// A movable shape for [quality] on [root], placed as low on the neck as possible.
  static Chord? generate(int root, ChordQuality quality) {
    Chord? best;
    for (final shape in _shapes[quality] ?? const <_Shape>[]) {
      final open = shape.rootString == 6 ? 4 : 9;
      var r = (root - open) % 12;
      if (r < shape.minFret) r += 12;
      final c = shape.build(r, root, quality);
      if (best == null || c.baseFret < best.baseFret) best = c;
    }
    return best;
  }
}

/// A movable chord shape: fret offsets from the root fret per string (low E first, null =
/// muted), fingers, and the strings the index-finger barre covers.
class _Shape {
  const _Shape(this.rootString, this.offsets, this.fingers, {this.barreFrom, this.minFret = 0});

  final int rootString;
  final List<int?> offsets;
  final List<int> fingers;
  final int? barreFrom;

  /// Lowest root fret the shape works at (1 when a string sits a fret below the root).
  final int minFret;

  Chord build(int r, int root, ChordQuality quality) {
    final name = '${commonRootName(root, minor: quality.isMinor)}${quality.suffix}';
    final frets = [for (final o in offsets) o == null ? -1 : r + o];
    return Chord(
      id: 'gen:$name',
      name: '$name (movable)',
      symbol: name,
      category: barreFrom == null || r == 0 ? 'generated' : 'barre',
      frets: frets,
      fingers: [for (var i = 0; i < 6; i++) frets[i] <= 0 ? 0 : fingers[i]],
      // At fret 0 the "barre" is just open strings.
      barre: barreFrom == null || r == 0 ? null : Barre(fret: r, from: barreFrom!, to: 1),
    );
  }
}

const _shapes = <ChordQuality, List<_Shape>>{
  ChordQuality.major: [
    _Shape(6, [0, 2, 2, 1, 0, 0], [1, 3, 4, 2, 1, 1], barreFrom: 6),
    _Shape(5, [null, 0, 2, 2, 2, 0], [0, 1, 2, 3, 4, 1], barreFrom: 5),
  ],
  ChordQuality.minor: [
    _Shape(6, [0, 2, 2, 0, 0, 0], [1, 3, 4, 1, 1, 1], barreFrom: 6),
    _Shape(5, [null, 0, 2, 2, 1, 0], [0, 1, 3, 4, 2, 1], barreFrom: 5),
  ],
  ChordQuality.dom7: [
    _Shape(6, [0, 2, 0, 1, 0, 0], [1, 3, 1, 2, 1, 1], barreFrom: 6),
    _Shape(5, [null, 0, 2, 0, 2, 0], [0, 1, 3, 1, 4, 1], barreFrom: 5),
  ],
  ChordQuality.min7: [
    _Shape(6, [0, 2, 0, 0, 0, 0], [1, 3, 1, 1, 1, 1], barreFrom: 6),
    _Shape(5, [null, 0, 2, 0, 1, 0], [0, 1, 3, 1, 2, 1], barreFrom: 5),
  ],
  ChordQuality.maj7: [
    _Shape(5, [null, 0, 2, 1, 2, 0], [0, 1, 3, 2, 4, 1], barreFrom: 5),
  ],
  ChordQuality.sus2: [
    _Shape(5, [null, 0, 2, 2, 0, 0], [0, 1, 3, 4, 1, 1], barreFrom: 5),
  ],
  ChordQuality.sus4: [
    _Shape(6, [0, 2, 2, 2, 0, 0], [1, 2, 3, 4, 1, 1], barreFrom: 6),
    _Shape(5, [null, 0, 2, 2, 3, 0], [0, 1, 2, 3, 4, 1], barreFrom: 5),
  ],
  ChordQuality.dom7sus4: [
    _Shape(5, [null, 0, 2, 0, 3, 0], [0, 1, 3, 1, 4, 1], barreFrom: 5),
  ],
  ChordQuality.add9: [
    _Shape(5, [null, 0, 2, 4, 2, 0], [0, 1, 2, 4, 3, 1], barreFrom: 5),
  ],
  ChordQuality.dom9: [
    _Shape(5, [null, 0, -1, 0, 0, 0], [0, 2, 1, 3, 3, 3], minFret: 1),
  ],
  ChordQuality.six: [
    _Shape(5, [null, 0, 2, 2, 2, 2], [0, 1, 3, 3, 3, 3]),
  ],
  ChordQuality.min6: [
    _Shape(5, [null, 0, 2, 2, 1, 2], [0, 1, 3, 3, 2, 4]),
  ],
  ChordQuality.power: [
    _Shape(6, [0, 2, 2, null, null, null], [1, 3, 4, 0, 0, 0]),
    _Shape(5, [null, 0, 2, 2, null, null], [0, 1, 3, 4, 0, 0]),
  ],
  ChordQuality.dim: [
    _Shape(5, [null, 0, 1, 2, 1, null], [0, 1, 2, 4, 3, 0]),
  ],
  ChordQuality.dim7: [
    _Shape(5, [null, 0, 1, -1, 1, null], [0, 2, 3, 1, 4, 0], minFret: 1),
  ],
  ChordQuality.halfDim: [
    _Shape(5, [null, 0, 1, 0, 1, null], [0, 1, 3, 2, 4, 0]),
  ],
  ChordQuality.aug: [
    _Shape(5, [null, 0, 3, 2, 2, null], [0, 1, 4, 2, 3, 0]),
  ],
};

extension ChordCapo on Chord {
  /// The same shape played with a capo at [capo], so "hear it" sounds at the real pitch.
  Chord withCapo(int capo) => capo <= 0
      ? this
      : Chord(
          id: '$id@$capo',
          name: name,
          symbol: symbol,
          category: category,
          frets: [for (final f in frets) f < 0 ? f : f + capo],
          fingers: fingers,
          barre: barre == null ? null : Barre(fret: barre!.fret + capo, from: barre!.from, to: barre!.to),
          tip: tip,
        );

  /// MIDI notes this shape sounds with a capo at [capo].
  List<int> midiWithCapo(int capo) => [
        for (var i = 0; i < 6; i++)
          if (frets[i] >= 0) midiAt(6 - i, frets[i] + capo),
      ];
}
