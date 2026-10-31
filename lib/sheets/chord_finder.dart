import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/analysis.dart';
import '../music/notes.dart';
import 'chord_symbol.dart';
import 'melody_finder.dart';

/// A chord the finder settled on, from [start] to [end] seconds.
class FoundChord {
  FoundChord(this.name, this.start, this.end);

  final String name;
  final double start;
  double end;
}

/// Writes down the chords of music it hears (a song playing from a speaker, or someone
/// playing), including music that never strums a whole chord: notes picked one string at a
/// time, a melody over a chord, two-note shapes. Its [melody] writes down the tune as well,
/// and [toSheetText] puts both on a sheet: the chords, and the melody as tab under them.
///
/// Each quarter second of sound becomes a 12-note profile (chroma), with overtones counting
/// less than the notes that made them, plus the bass note. Every major and minor triad, and
/// "no chord", scores how well it explains each profile: its own notes are likely, any other
/// note possible (a melody, a passing note). A Viterbi pass then finds the sequence of chords
/// that explains everything heard best, paying [changeCost] for each change. So notes played
/// one at a time add up to the chord they belong to, a brief passing note can't pay for two
/// changes, a drum fill carries the chord on, and silence reads as no chord. The song's key,
/// estimated from everything heard, nudges chords that belong to it, which is what tells A from
/// Am when only A and E are played. The whole song is decoded again as it goes, so an early
/// guess can still be corrected by what comes after.
class ChordFinder {
  ChordFinder({
    this.windowSeconds = 0.25,
    this.changeCost = 3.5,
    this.keyWeight = 0.15,
    this.overtoneWeight = 0.5,
    this.bassWeight = 0.8,
    this.heldChangeCost = 1.3,
    this.noneCost = 1,
  });

  final double windowSeconds;

  /// Evidence (log-likelihood) a chord change has to earn; higher means fewer, surer changes.
  final double changeCost;

  /// How much belonging to the song's key counts for a chord, per quarter second.
  final double keyWeight;

  /// How much a likely overtone (3rd, 5th, 6th... harmonic of a lower note) counts toward its
  /// own note name. Those land on other note names (a D's 3rd harmonic is an A), so a single
  /// string would otherwise read as a chord; octaves are harmless and kept.
  final double overtoneWeight;

  /// How much the bass note counts, next to all the notes together. It's usually the root.
  final double bassWeight;

  /// How many times [changeCost] a change costs where nothing new was struck underneath (a
  /// melody note, held notes), so chords change with strums and bass notes, not with a melody.
  final double heldChangeCost;

  /// What "no chord" pays for each quarter second with pitched sound in it.
  final double noneCost;

  /// The best guess right now, for a live display (null in silence).
  String? live;
  double liveConfidence = 0;

  /// Seconds listened so far.
  double elapsed = 0;

  /// The tune, heard from the same frames on the same clock.
  final melody = MelodyFinder();

  // The 24 triads (root * 2 + minor) and "no chord".
  static const _none = 24, _states = 25;

  // Chords settled before the clock jumped back (a video wound back), then the song decoded now.
  final _settled = <FoundChord>[];
  var _decoded = <FoundChord>[];

  final _windows = <_Window>[];
  final _chroma = Float64List(12), _bass = Float64List(12);
  final _keyChroma = Float64List(12);
  int _voiced = 0;
  double? _origin, _windowStart, _lastRaw;
  int _sounding = 0, _frames = 0;
  bool _attacked = false, _attackedBefore = false;
  int? _lastBass;

  // Viterbi: best score of a path ending in each state, and each window's best predecessors.
  final _score = Float64List(_states);
  final _from = <Int8List>[];
  Set<int> _keyChords = const {};

  /// The chords so far, oldest first. The last few can still change as more is heard.
  List<FoundChord> get chords => [..._settled, ..._decoded];

  void clear() {
    melody.clear();
    _settled.clear();
    _decoded = [];
    _restart();
    _keyChroma.fillRange(0, 12, 0);
    _voiced = 0;
    _keyChords = const {};
    live = null;
    liveConfidence = 0;
    _origin = _windowStart = _lastRaw = null;
    elapsed = 0;
  }

  /// Feeds one analysis frame; returns true when [live] or [chords] changed.
  ///
  /// Times are seconds since listening started. With [at], the frame is placed at that time
  /// instead (the position of a video playing in the app), so chords line up with the video.
  bool add(AnalysisFrame f, {double? at}) {
    double t;
    if (at != null) {
      t = at;
    } else {
      _origin ??= f.time;
      // After a pause the mic restarts its clock; carry on from where listening stopped.
      if (_lastRaw != null && f.time < _lastRaw!) _origin = f.time - elapsed;
      _lastRaw = f.time;
      t = f.time - _origin!;
    }
    elapsed = t;
    melody.add(f, t);
    _windowStart ??= t;
    // The video was wound back: keep what was found, and start a new stretch from here.
    if (t < _windowStart!) {
      _settled.addAll(_decoded);
      _decoded = [];
      _restart();
      _windowStart = t;
    }
    _frames++;
    if (f.onsets.isNotEmpty) _attacked = true;
    if (f.hasSound) {
      _sounding++;
      _addFrame(f);
    }
    if (t - _windowStart! < windowSeconds) return false;
    final before = _shown;
    _closeWindow(_windowStart!, t);
    _windowStart = t;
    return _shown != before;
  }

  /// What a display shows: the live guess and every chord's name and start. A key change can
  /// rewrite chords anywhere in the song, not just the last one.
  int get _shown => Object.hashAll([live, for (final c in _decoded) ...[c.name, c.start]]);

  void _addFrame(AnalysisFrame f) {
    final peaks = [...f.peaks]..sort((a, b) => a.frequency.compareTo(b.frequency));
    for (var i = 0; i < peaks.length; i++) {
      final p = peaks[i];
      final midi = freqToMidi(p.frequency);
      final nearest = midi.round();
      if ((midi - nearest).abs() > 0.35) continue;
      var w = math.sqrt(p.magnitude) * (p.frequency < 1000 ? 1.0 : 0.5);
      if (_isOvertone(peaks, i)) w *= overtoneWeight;
      _chroma[nearest % 12] += w;
      if (p.frequency < _bassBelow) _bass[nearest % 12] += w;
    }
  }

  /// Whether peak [i] sits on a harmonic of a lower, comparably loud peak that names a different
  /// note (3rd, 5th, 6th, 7th, 9th... not the octaves).
  static bool _isOvertone(List<SpectralPeak> byFreq, int i) {
    final p = byFreq[i];
    for (var j = 0; j < i; j++) {
      final q = byFreq[j];
      if (q.magnitude < 0.2 * p.magnitude) continue;
      final ratio = p.frequency / q.frequency;
      final h = ratio.round();
      if (h < 3 || h > 16 || h & (h - 1) == 0) continue;
      if ((1200 * math.log(ratio / h) / math.ln2).abs() < 30) return true;
    }
    return false;
  }

  void _closeWindow(double start, double end) {
    final total = _chroma.fold<double>(0, (a, v) => a + v);
    final voiced = _sounding * 2 >= _frames && total > 0;
    final evidence = Float64List(_states);
    Float64List? profile;
    var fresh = false;
    if (voiced) {
      profile = Float64List.fromList([for (final v in _chroma) v / total]);
      // Several notes at once (a strum) say more about the chord than one note, which may just
      // be a melody: up to twice as much. One note at a time (an arpeggio) still adds up.
      final notes = profile.where((v) => v >= _noteShare).length;
      final weight = math.min(2.0, 1 + 0.5 * (notes - 1));
      final bassTotal = _bass.fold<double>(0, (a, v) => a + v);
      // Chords change where something new is struck underneath: a strum, or a new bass note.
      int? bass;
      if (bassTotal > 0) {
        bass = 0;
        for (var pc = 1; pc < 12; pc++) {
          if (_bass[pc] > _bass[bass!]) bass = pc;
        }
      }
      // A window that starts mid-strike still sounds mostly like what came before, so a strike
      // counts for the next window too.
      final struck = _attacked || _attackedBefore;
      fresh = struck && (notes >= 3 || (bass != null && bass != _lastBass));
      if (bass != null) _lastBass = bass;
      for (var k = 0; k < _states; k++) {
        var e = 0.0;
        for (var pc = 0; pc < 12; pc++) {
          if (profile[pc] > 0) e += profile[pc] * _logNote[k][pc];
        }
        if (bassTotal > 0) {
          for (var pc = 0; pc < 12; pc++) {
            if (_bass[pc] > 0) e += bassWeight * _bass[pc] / bassTotal * _logBass[k][pc];
          }
        }
        evidence[k] = weight * e;
      }
      // Sound with pitch in it is rarely "no chord".
      evidence[_none] -= noneCost;
      for (var pc = 0; pc < 12; pc++) {
        _keyChroma[pc] += profile[pc];
      }
      _voiced++;
    } else {
      // Silence (or too little sound to tell): says nothing about which chord, a little for none.
      for (var k = 0; k < _none; k++) {
        evidence[k] = -_silenceCost;
      }
    }
    _chroma.fillRange(0, 12, 0);
    _bass.fillRange(0, 12, 0);
    _sounding = 0;
    _frames = 0;
    _attackedBefore = _attacked;
    _attacked = false;

    _windows.add(_Window(start, end, evidence, profile, fresh: fresh));
    final key = _voiced >= _keyAfter ? _keyChordsFor(_keyChroma) : const <int>{};
    if (!_sameSet(key, _keyChords)) {
      // The key changed (or became clear): decode the whole stretch again with it.
      _keyChords = key;
      _resetDecoder();
      for (final w in _windows) {
        _step(w);
      }
    } else {
      _step(_windows.last);
    }
    _decode();
  }

  /// Advances the Viterbi scores by one window.
  void _step(_Window w) {
    final e = w.evidence;
    final from = Int8List(_states);
    if (_from.isEmpty) {
      // Start from no chord: the first chord pays half a change, like any start after silence.
      for (var k = 0; k < _states; k++) {
        _score[k] = (k == _none ? 0 : -changeCost / 2) + e[k] + _keyBonus(k, w);
        from[k] = k;
      }
      _from.add(from);
      return;
    }
    // The two best chords to come from, so each chord can switch from the best *other* one.
    var best = -1, second = -1;
    for (var k = 0; k < _none; k++) {
      if (best < 0 || _score[k] > _score[best]) {
        second = best;
        best = k;
      } else if (second < 0 || _score[k] > _score[second]) {
        second = k;
      }
    }
    final next = Float64List(_states);
    for (var k = 0; k < _states; k++) {
      var s = _score[k];
      var f = k;
      if (k == _none) {
        if (_score[best] - changeCost / 2 > s) {
          s = _score[best] - changeCost / 2;
          f = best;
        }
      } else {
        if (_score[_none] - changeCost / 2 > s) {
          s = _score[_none] - changeCost / 2;
          f = _none;
        }
        final other = best == k ? second : best;
        // Changing on a melody note, or while notes are held, takes more evidence.
        final cost = w.fresh ? changeCost : changeCost * heldChangeCost;
        if (_score[other] - cost > s) {
          s = _score[other] - cost;
          f = other;
        }
      }
      next[k] = s + e[k] + _keyBonus(k, w);
      from[k] = f;
    }
    _score.setAll(0, next);
    _from.add(from);
  }

  double _keyBonus(int state, _Window w) => w.profile != null && _keyChords.contains(state) ? keyWeight : 0;

  /// Reads the best path back into chords, and the live guess off its end.
  void _decode() {
    final n = _windows.length;
    var state = 0;
    for (var k = 1; k < _states; k++) {
      if (_score[k] > _score[state]) state = k;
    }
    final path = Int8List(n);
    for (var i = n - 1; i >= 0; i--) {
      path[i] = state;
      state = _from[i][state];
    }
    final found = <FoundChord>[];
    for (var i = 0; i < n; i++) {
      final s = path[i];
      if (s == _none) continue;
      final w = _windows[i];
      final name = _name(s);
      // A chord heard again after a gap carries on; a new one starts where its evidence did.
      if (found.isNotEmpty && found.last.name == name) {
        found.last.end = w.end;
      } else {
        found.add(FoundChord(name, w.start, w.end));
      }
    }
    _decoded = found;

    final now = path[n - 1];
    if (now == _none || _windows.last.profile == null) {
      live = null;
      liveConfidence = 0;
      return;
    }
    live = _name(now);
    // How much of the last second's sound the chord's notes explain, and how many of them
    // were actually heard: one note alone isn't much to go on.
    final recent = Float64List(12);
    for (var i = math.max(0, n - 4); i < n; i++) {
      final p = _windows[i].profile;
      if (p == null) continue;
      for (var pc = 0; pc < 12; pc++) {
        recent[pc] += p[pc];
      }
    }
    final tones = _tones(now);
    final total = recent.fold<double>(0, (a, v) => a + v);
    final top = recent.reduce(math.max);
    final explained = tones.fold<double>(0, (a, pc) => a + recent[pc]) / total;
    final heard = tones.where((pc) => recent[pc] >= 0.15 * top).length / 3;
    liveConfidence = (explained * (0.6 + 0.4 * heard)).clamp(0.0, 1.0);
  }

  /// Starts a new stretch: no windows yet, nothing heard in the current one.
  void _restart() {
    _windows.clear();
    _resetDecoder();
    _chroma.fillRange(0, 12, 0);
    _bass.fillRange(0, 12, 0);
    _sounding = 0;
    _frames = 0;
    _attacked = _attackedBefore = false;
    _lastBass = null;
  }

  void _resetDecoder() {
    _from.clear();
    _score.fillRange(0, _states, 0);
  }

  static bool _sameSet(Set<int> a, Set<int> b) => a.length == b.length && a.containsAll(b);

  static String _name(int state) {
    final root = state ~/ 2, minor = state.isOdd;
    return '${commonRootName(root, minor: minor)}${minor ? 'm' : ''}';
  }

  /// Root, third and fifth of a triad state.
  static List<int> _tones(int state) {
    final root = state ~/ 2;
    return [root, (root + (state.isOdd ? 3 : 4)) % 12, (root + 7) % 12];
  }

  // How likely each note is under each state (log): a chord's own notes, then anything else
  // (a melody's passing notes) at a lower rate; "no chord" finds every note equally likely.
  static const _rootShare = 0.28, _thirdShare = 0.22, _fifthShare = 0.24;
  static const _silenceCost = 0.3, _keyAfter = 8, _noteShare = 0.12;

  /// Bass notes: up to E3, where the roots of guitar chords on the bottom strings sit.
  static const _bassBelow = 165.0;
  static final _logNote = _table((state, pc) {
    if (state == _none) return 1 / 12;
    final t = _tones(state);
    if (pc == t[0]) return _rootShare;
    if (pc == t[1]) return _thirdShare;
    if (pc == t[2]) return _fifthShare;
    return (1 - _rootShare - _thirdShare - _fifthShare) / 9;
  });
  // The bass mostly plays the root.
  static final _logBass = _table((state, pc) {
    if (state == _none) return 1 / 12;
    final t = _tones(state);
    if (pc == t[0]) return 0.55;
    if (pc == t[1]) return 0.1;
    if (pc == t[2]) return 0.15;
    return 0.2 / 9;
  });

  static List<Float64List> _table(double Function(int state, int pc) p) => [
        for (var k = 0; k < _states; k++) Float64List.fromList([for (var pc = 0; pc < 12; pc++) math.log(p(k, pc))]),
      ];

  // Krumhansl-Kessler key profiles, tonic first.
  static const _majorProfile = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
  static const _minorProfile = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];

  /// The triads that belong to the key [chroma] fits best (with the major V of a minor key).
  static Set<int> _keyChordsFor(Float64List chroma) {
    var best = -2.0, tonic = 0, minor = false;
    for (var t = 0; t < 12; t++) {
      for (final m in const [false, true]) {
        final r = _correlation(chroma, m ? _minorProfile : _majorProfile, t);
        if (r > best) {
          best = r;
          tonic = t;
          minor = m;
        }
      }
    }
    int maj(int i) => ((tonic + i) % 12) * 2;
    int min(int i) => ((tonic + i) % 12) * 2 + 1;
    return minor
        ? {min(0), maj(3), min(5), min(7), maj(7), maj(8), maj(10)}
        : {maj(0), min(2), min(4), maj(5), maj(7), min(9)};
  }

  static double _correlation(Float64List x, List<double> profile, int tonic) {
    var mx = 0.0, my = 0.0;
    for (var i = 0; i < 12; i++) {
      mx += x[i];
      my += profile[i];
    }
    mx /= 12;
    my /= 12;
    var sxy = 0.0, sxx = 0.0, syy = 0.0;
    for (var i = 0; i < 12; i++) {
      final dx = x[(tonic + i) % 12] - mx, dy = profile[i] - my;
      sxy += dx * dy;
      sxx += dx * dx;
      syy += dy * dy;
    }
    return sxx == 0 ? -1 : sxy / math.sqrt(sxx * syy);
  }

  /// What was found as a ChordPro sheet: the chords, [perLine] to a line (a chord held much
  /// longer than the typical one is repeated, so the chart keeps a rough sense of time), then
  /// the melody as tab with the chords over its bars, at the tempo it was heard.
  String toSheetText({int perLine = 4}) {
    final found = chords;
    final tune = melody.tune;
    final hasTune = tune.isNotEmpty;
    if (found.isEmpty && !hasTune) return '';
    final out = StringBuffer();
    final bpm = hasTune ? tempoOf([...melody.onsets, for (final n in tune) n.start]) ?? 90 : null;
    final bars = bpm == null ? null : barsOf([for (final c in found) c.start], bpm);
    if (bpm != null) out.writeln('{tempo: $bpm}');
    if (bars != null && bars.beats != 4) out.writeln('{time: ${bars.beats}/4}');
    if (found.isNotEmpty) {
      final lengths = [for (final c in found) c.end - c.start]..sort();
      final typical = math.max(lengths[lengths.length ~/ 2], 1.0);
      final names = <String>[
        for (final c in found)
          for (var i = 0; i < ((c.end - c.start) / typical).round().clamp(1, 4); i++) c.name,
      ];
      out.writeln('{comment: Chords found by listening}');
      for (var i = 0; i < names.length; i += perLine) {
        out.writeln(
            names.sublist(i, math.min(i + perLine, names.length)).map((n) => '[$n]'.padRight(8)).join().trimRight());
      }
    }
    if (bpm != null) {
      out
        ..writeln()
        ..writeln(melodyTab(tune,
            bpm: bpm,
            beatsPerBar: bars!.beats,
            downbeat: bars.downbeat,
            chords: [for (final c in found) (c.start, c.name)]));
    }
    return out.toString().trimRight();
  }
}

/// A quarter second of what was heard: how well each state explains it, and its note profile
/// (null when it was too quiet to tell).
class _Window {
  _Window(this.start, this.end, this.evidence, this.profile, {required this.fresh});

  final double start, end;
  final Float64List evidence;
  final Float64List? profile;

  /// Whether something new was struck underneath (a strum, a new bass note).
  final bool fresh;
}

/// Seconds as "1:05".
String formatSeconds(double s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

/// Whether [name] is something [ChordFinder] can write (a major or minor triad).
bool isFinderChord(String name) {
  final s = ChordSymbol.tryParse(name);
  return s != null && (s.quality == ChordQuality.major || s.quality == ChordQuality.minor);
}
