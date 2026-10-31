import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/analysis.dart';
import '../music/notes.dart';

/// A note of a melody: [midi] from [start] to [end] seconds.
class MelodyNote {
  MelodyNote(this.midi, this.start, this.end);

  final int midi;
  final double start;
  double end;

  /// How far the note stood out: its salience over the strongest note unrelated to it (not
  /// its octaves, nor the notes its overtones land on), averaged over the note. A sung or
  /// lead line stands out; the top note of a strummed chord barely does.
  double standsOut = 0;
}

/// Writes down the melody of what it hears: the line you would sing back, whether it's sung
/// over a band or picked one string at a time.
///
/// Every frame, each note in the melody's range gets a salience: the share of the sound its
/// harmonics would explain, the fundamental counting most so that a note isn't taken for the
/// octave below. A clear single pitch from the pitch detector adds to its note. A Viterbi pass
/// then follows the strongest line through the frames, paying for each semitone of a leap and
/// for starting and stopping, so it keeps to the tune rather than jumping between the notes of
/// the chords around it; where no note stands out it rests. Runs of one pitch become notes,
/// split where the same note is struck again.
class MelodyFinder {
  MelodyFinder({
    this.lowest = 48,
    this.highest = 84,
    this.voicing = 0.15,
    this.leapCost = 0.08,
    this.startCost = 0.5,
    this.pitchWeight = 0.5,
    this.pitchClarity = 0.9,
    this.loudestPeaks = 16,
  });

  /// The melody's range, as MIDI notes (C3..C6).
  final int lowest, highest;

  /// How much of the sound a note must explain to be heard as the melody (otherwise a rest).
  final double voicing;

  /// What the line pays per semitone it leaps, and to start or stop a phrase.
  final double leapCost, startCost;

  /// How much a clear single pitch (from the pitch detector) adds to its note, from what
  /// clarity. Under a band the detector locks onto the bass or the wrong octave, so only a
  /// really clear pitch counts.
  final double pitchWeight, pitchClarity;

  /// A note's salience is its share of this many of the loudest peaks: the rest of a full mix
  /// (cymbals, overtones of the chords) shouldn't drown out a melody that stands out.
  final int loudestPeaks;

  int get _notes => highest - lowest + 1;
  int get _rest => _notes; // the state index for "no melody"

  // Per frame: time, salience of each note then the rest score, and whether a note was struck.
  final _times = <double>[];
  final _scores = <Float32List>[];
  final _struck = <bool>[];
  final _onsetAt = <double?>[];
  final _rms = <double>[];
  final _pitch = <int?>[]; // the pitch detector's note, when it's clear
  final _from = <Int8List>[];
  Float64List? _delta;

  // Notes from before the clock jumped back (a video wound back).
  final _settled = <MelodyNote>[];
  List<MelodyNote>? _decoded;

  /// Onset times heard, for the tempo.
  final onsets = <double>[];

  void clear() {
    _settled.clear();
    onsets.clear();
    _restart();
  }

  void _restart() {
    _times.clear();
    _scores.clear();
    _struck.clear();
    _onsetAt.clear();
    _rms.clear();
    _pitch.clear();
    _from.clear();
    _delta = null;
    _decoded = null;
  }

  /// Feeds one analysis frame heard at [time] seconds (on the listening clock).
  void add(AnalysisFrame f, double time) {
    if (_times.isNotEmpty && time < _times.last) {
      // The clock went back (a video wound back): keep what was found, start again from here.
      _settled.addAll(_decode());
      _restart();
    }
    final scores = Float32List(_notes + 1);
    if (f.hasSound) _salience(f, scores);
    scores[_rest] = voicing;
    // Onsets are placed by stream time; on the listening clock they sit as far before [time].
    final onset = f.onsets.isEmpty ? null : time - (f.time - f.onsets.last);
    for (final o in f.onsets) {
      onsets.add(time - (f.time - o));
    }
    _times.add(time);
    _scores.add(scores);
    _struck.add(onset != null);
    _onsetAt.add(onset);
    _rms.add(f.rms);
    final p = f.pitch;
    _pitch.add(p != null && p.clarity >= 0.85 ? p.midi.round() : null);
    _step(scores);
    _decoded = null;
  }

  static const _harmonics = 6, _falloff = 0.8, _window = 40.0, _maxFreq = 2100.0;

  /// Fills [scores] with each note's salience in [f].
  void _salience(AnalysisFrame f, Float32List scores) {
    final peaks = [...f.peaks]..sort((a, b) => a.frequency.compareTo(b.frequency));
    if (peaks.isEmpty) return;
    final cents = [for (final p in peaks) 1200 * math.log(p.frequency / 440) / math.ln2];
    final weight = [for (final p in peaks) math.sqrt(p.magnitude)];
    final loudest = [...weight]..sort((a, b) => b.compareTo(a));
    final total = loudest.take(loudestPeaks).fold<double>(0, (a, b) => a + b);
    for (var k = 0; k < _notes; k++) {
      final f0 = midiToFreq(lowest + k);
      var s = 0.0, h = 1, gain = 1.0;
      for (; h <= _harmonics && f0 * h <= _maxFreq; h++, gain *= _falloff) {
        final target = 1200 * math.log(f0 * h / 440) / math.ln2;
        // The nearest peak to this harmonic, within the window.
        var best = 0.0;
        for (var i = _firstAbove(cents, target - _window); i < cents.length && cents[i] <= target + _window; i++) {
          final c = weight[i] * (1 - (cents[i] - target).abs() / _window);
          if (c > best) best = c;
        }
        s += gain * best;
      }
      scores[k] = s / total;
    }
    final pitch = f.pitch;
    if (pitch != null && pitch.clarity >= pitchClarity) {
      final k = pitch.midi.round() - lowest;
      if (k >= 0 && k < _notes) scores[k] += pitchWeight * pitch.clarity;
    }
  }

  /// Whether the note sounding at frame [i] is struck again there: an attack, and either a
  /// clean pitch on it (one instrument, re-picked) or the level dipping and rising again (a
  /// singer re-articulating). A strum or a drum under a held note only adds; it doesn't dip.
  ///
  /// The attack frame itself is often a transient: the level jump and the clean pitch can come
  /// a frame later, so both are looked for there and in the next frame.
  bool _struckAgain(int i, int midi) {
    if (i < 3 || !(_struck[i] || _struck[i - 1])) return false;
    final attack = _struck[i] ? i : i - 1;
    final after = math.min(attack + 1, _rms.length - 1);
    // Clean on the attack itself, or just after it if the note kept its share of the sound (a
    // strum under a held note dilutes it; a note struck again doesn't).
    final k = midi - lowest;
    final onAttack = _pitch[attack] == midi && _rms[attack] > 1.2 * _rms[attack - 1];
    final justAfter = _pitch[after] == midi &&
        math.max(_rms[attack], _rms[after]) > 1.2 * _rms[attack - 1] &&
        _scores[after][k] >= 0.8 * _scores[attack - 1][k];
    final clean = onAttack || justAfter;
    final before = math.max(_rms[i - 2], _rms[i - 3]);
    final dip = _rms[i - 1] < 0.7 * before && _rms[i] > 1.4 * _rms[i - 1];
    return clean || dip;
  }

  static int _firstAbove(List<double> sorted, double value) {
    var lo = 0, hi = sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (sorted[mid] < value) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Advances the Viterbi scores by one frame.
  void _step(Float32List e) {
    final n = _notes, rest = _rest;
    final from = Int8List(n + 1);
    final prev = _delta;
    if (prev == null) {
      _delta = Float64List(n + 1);
      for (var k = 0; k < n; k++) {
        _delta![k] = e[k] - startCost;
        from[k] = k;
      }
      _delta![rest] = e[rest];
      from[rest] = rest;
      _from.add(from);
      return;
    }
    // max over j of prev[j] - leapCost * |j - k|, for every k at once: one pass up, one down.
    final best = Float64List(n), arg = Int32List(n);
    for (var k = 0; k < n; k++) {
      best[k] = prev[k];
      arg[k] = k;
      if (k > 0 && best[k - 1] - leapCost > best[k]) {
        best[k] = best[k - 1] - leapCost;
        arg[k] = arg[k - 1];
      }
    }
    for (var k = n - 2; k >= 0; k--) {
      if (best[k + 1] - leapCost > best[k]) {
        best[k] = best[k + 1] - leapCost;
        arg[k] = arg[k + 1];
      }
    }
    final next = Float64List(n + 1);
    var top = 0;
    for (var k = 0; k < n; k++) {
      if (prev[k] > prev[top]) top = k;
      var s = best[k], f = arg[k];
      if (prev[rest] - startCost > s) {
        s = prev[rest] - startCost;
        f = rest;
      }
      next[k] = s + e[k];
      from[k] = f;
    }
    if (prev[top] - startCost > prev[rest]) {
      next[rest] = prev[top] - startCost + e[rest];
      from[rest] = top;
    } else {
      next[rest] = prev[rest] + e[rest];
      from[rest] = rest;
    }
    _delta = next;
    _from.add(from);
  }

  /// The melody so far, oldest note first. The last few notes can still change.
  List<MelodyNote> get notes => [..._settled, ..._decode()];

  /// [notes] when they make a tune that stands out from what's around it (sung, or picked
  /// over chords); empty when they're only the top of strummed or arpeggiated chords. Measured
  /// on test songs, a tune's notes stand out about 1.3 times or more on average, a chord's top
  /// note under 1.25.
  List<MelodyNote> get tune {
    final found = notes;
    if (found.length < 4) return const [];
    final standing = [for (final n in found) n.standsOut]..sort();
    return standing[standing.length ~/ 2] >= 1.26 ? found : const [];
  }

  List<MelodyNote> _decode() {
    if (_decoded != null) return _decoded!;
    final n = _times.length;
    if (n == 0) return _decoded = [];
    final delta = _delta!;
    var state = 0;
    for (var k = 1; k < delta.length; k++) {
      if (delta[k] > delta[state]) state = k;
    }
    final path = Int32List(n);
    for (var i = n - 1; i >= 0; i--) {
      path[i] = state;
      state = _from[i][state];
    }
    // Runs of one pitch are notes; the same pitch struck again (an onset as it gets louder)
    // starts a new one.
    final found = <MelodyNote>[];
    final frames = <int>[]; // how many frames each found note lasted
    double standsOut(int i, int k) {
      var other = 1e-6;
      for (var j = 0; j < _notes; j++) {
        if (const {0, 12, 19, 24, 28}.contains((j - k).abs())) continue;
        if (_scores[i][j] > other) other = _scores[i][j];
      }
      return _scores[i][k] / other;
    }

    final hop = n > 1 ? (_times.last - _times.first) / (n - 1) : 0.05;
    MelodyNote? current;
    var started = 0;
    for (var i = 0; i < n; i++) {
      final k = path[i];
      if (k == _rest) {
        current = null;
        continue;
      }
      // Struck again, and still that note a moment later: not the tail of a note just as the
      // tune moves on.
      final again = current != null &&
          current.midi == lowest + k &&
          i - started >= 3 && // one attack, one new note
          _struckAgain(i, lowest + k) &&
          i + 3 <= n &&
          path.sublist(i, i + 3).every((p) => p == k);
      if (current == null || current.midi != lowest + k || again) {
        // The note began a little before the frame that heard it: at its onset, if one was heard.
        final onset = _onsetAt[i];
        final start = onset != null && onset > _times[i] - 0.25 ? onset : _times[i] - 2 * hop;
        current = MelodyNote(lowest + k, start, _times[i])..standsOut = standsOut(i, k);
        found.add(current);
        frames.add(1);
        started = i;
      } else {
        current.end = _times[i];
        frames.last++;
        current.standsOut += (standsOut(i, k) - current.standsOut) / frames.last;
      }
    }
    // A note heard in a single frame is a slide or a smudge.
    return _decoded = [
      for (var j = 0; j < found.length; j++)
        if (frames[j] >= 2) found[j],
    ];
  }
}

/// The tempo (beats per minute) that best fits [onsets]: the beat whose multiples the gaps
/// between them land on, leaning toward common tempos (around 100) to settle double or half
/// time. Null when there are too few onsets to tell.
int? tempoOf(List<double> onsets) {
  if (onsets.length < 8) return null;
  final times = [...onsets]..sort();
  var best = 0;
  var bestScore = 0.0;
  for (var bpm = 50; bpm <= 180; bpm++) {
    final beat = 60 / bpm;
    var score = 0.0;
    for (var i = 0; i < times.length; i++) {
      for (var j = i + 1; j < times.length && times[j] - times[i] < 4.5 * beat; j++) {
        final gap = times[j] - times[i];
        // Gaps of one, two or four beats, within a few hundredths of a second.
        for (final beats in const [1, 2, 4]) {
          final miss = gap - beats * beat;
          score += math.exp(-miss * miss / (2 * 0.025 * 0.025));
        }
      }
    }
    final octaves = math.log(bpm / 100) / math.ln2;
    score *= math.exp(-octaves * octaves / (2 * 0.6 * 0.6));
    if (score > bestScore) {
      bestScore = score;
      best = bpm;
    }
  }
  return best == 0 ? null : best;
}

/// The bars the chords fit: beats in a bar (3 or 4) for chords changing at [changes]
/// (seconds) at [bpm], and a downbeat (a change on the first beat of a bar). Songs change
/// chord at the start of a bar, so the bar length and phase that put most changes there win;
/// 4/4 unless 3/4 fits clearly better.
({int beats, double? downbeat}) barsOf(List<double> changes, int bpm) {
  if (changes.length < 3) return (beats: 4, downbeat: changes.isEmpty ? null : changes.first);
  final beat = 60 / bpm;
  var best = (beats: 4, downbeat: changes.first as double?);
  var bestFit = -1.0;
  for (final beats in const [4, 3]) {
    for (final origin in changes) {
      var on = 0;
      for (final t in changes) {
        final bars = (t - origin) / beat / beats;
        if ((bars - bars.round()).abs() * beats < 0.4) on++;
      }
      final fit = on / changes.length + (beats == 4 ? 0.1 : 0);
      if (fit > bestFit) {
        bestFit = fit;
        best = (beats: beats, downbeat: origin);
      }
    }
  }
  return best;
}

/// [notes] as six-line guitar tab (ChordPro `start_of_tab` block), one column a sixteenth at
/// [bpm] so the tab player plays it back in time, four bars to a line, the bars starting at
/// [downbeat] (seconds). [chords] (start time, name) are written over the bars. The melody is
/// moved by octaves into the guitar's range and fingered to keep the hand still, in open
/// position where it can be.
String melodyTab(List<MelodyNote> notes,
    {required int bpm, List<(double, String)> chords = const [], int beatsPerBar = 4, double? downbeat}) {
  if (notes.isEmpty) return '';
  final sixteenth = 60 / bpm / 4;
  final barColumns = beatsPerBar * 4;
  // The chords say roughly where the bars start; the notes' own starts pin the beat down: slide
  // the grid to where the notes sit best on eighths. Under half an eighth either way: a whole
  // eighth would fit just as well, a beat off.
  var origin = downbeat ?? notes.first.start;
  var bestMiss = double.infinity, bestShift = 0.0;
  for (var shift = -sixteenth; shift < sixteenth; shift += 0.01) {
    var miss = 0.0;
    for (final n in notes) {
      final eighths = (n.start - origin - shift) / (2 * sixteenth);
      final d = eighths - eighths.round();
      miss += d * d;
    }
    if (miss < bestMiss) {
      bestMiss = miss;
      bestShift = shift;
    }
  }
  origin += bestShift;
  int column(double t) => ((t - origin) / sixteenth).round();

  // An octave that puts the tune between low E and E5, around A3 (an octave under how it's sung,
  // the way guitar music is written).
  final sorted = [for (final n in notes) n.midi]..sort();
  final median = sorted[sorted.length ~/ 2];
  var shift = 0;
  var bestCost = double.infinity;
  for (final k in const [-24, -12, 0, 12]) {
    final outside = sorted.where((m) => m + k < 40 || m + k > 76).length;
    final cost = (outside * 10 + (median + k - 57).abs()).toDouble();
    if (cost < bestCost) {
      bestCost = cost;
      shift = k;
    }
  }

  // Fingering: each note on a string and fret, the path that moves the hand least.
  const open = [64, 59, 55, 50, 45, 40]; // strings 1..6
  final pitches = <int>[];
  for (final n in notes) {
    var m = n.midi + shift;
    while (m < 40) {
      m += 12;
    }
    while (m > 76) {
      m -= 12;
    }
    pitches.add(m);
  }
  List<(int, int)> placesFor(int m) => [
        for (var s = 1; s <= 6; s++)
          if (m - open[s - 1] >= 0 && m - open[s - 1] <= 12) (s, m - open[s - 1]),
      ];
  final places = [for (final m in pitches) placesFor(m)];
  // Low frets are easier, and the fingers cover four frets without moving the hand: only a
  // reach past that costs (open strings never do).
  double own((int, int) p) => p.$2 * 0.15 + (p.$2 >= 5 ? 0.5 : 0) + (p.$2 >= 10 ? 1 : 0);
  double move((int, int) a, (int, int) b) =>
      a.$2 > 0 && b.$2 > 0 ? math.max(0, (a.$2 - b.$2).abs() - 3).toDouble() : 0;
  var cost = [for (final p in places.first) own(p)];
  final back = <List<int>>[];
  for (var i = 1; i < places.length; i++) {
    final next = <double>[], from = <int>[];
    for (final p in places[i]) {
      var best = 0;
      for (var j = 1; j < places[i - 1].length; j++) {
        if (cost[j] + move(places[i - 1][j], p) < cost[best] + move(places[i - 1][best], p)) best = j;
      }
      next.add(cost[best] + move(places[i - 1][best], p) + own(p));
      from.add(best);
    }
    cost = next;
    back.add(from);
  }
  var pick = 0;
  for (var j = 1; j < cost.length; j++) {
    if (cost[j] < cost[pick]) pick = j;
  }
  final chosen = List<(int, int)>.filled(notes.length, (1, 0));
  for (var i = notes.length - 1; i >= 0; i--) {
    chosen[i] = places[i][pick];
    if (i > 0) pick = back[i - 1][pick];
  }

  // Lay the notes out on the grid, a whole number of bars from the first to the last. Each note
  // goes to the nearest eighth, unless that's where the note before it went: then sixteenths.
  final columns = <int>[];
  for (final n in notes) {
    var c = ((n.start - origin) / (2 * sixteenth)).round() * 2;
    if (columns.isNotEmpty && c <= columns.last) c = math.max(column(n.start), columns.last + 1);
    columns.add(c);
  }
  final first = (columns.reduce(math.min) / barColumns).floor() * barColumns;
  final last = columns.reduce(math.max);
  final bars = (last - first) ~/ barColumns + 1;
  final cells = List.generate(6, (_) => List.filled(bars * barColumns, '-'));
  var taken = -1;
  for (var i = 0; i < notes.length; i++) {
    final c = columns[i] - first;
    if (c <= taken) continue; // two notes in one sixteenth: keep the first
    final (string, fret) = chosen[i];
    final text = '$fret';
    if (c + text.length > cells[0].length) continue;
    for (var d = 0; d < text.length; d++) {
      cells[string - 1][c + d] = text[d];
    }
    taken = c + text.length - 1;
  }
  final over = <int, String>{};
  for (final (start, name) in chords) {
    // Chords change on beats: put each on the nearest one.
    final c = ((column(start) - first) / 4).round() * 4;
    if (c >= 0 && c < bars * barColumns) over[c] = name;
  }

  final out = StringBuffer('{start_of_tab: Melody}\n');
  const names = ['e', 'B', 'G', 'D', 'A', 'E'];
  for (var b = 0; b < bars; b += 4) {
    final lineBars = math.min(4, bars - b);
    // The chord line, aligned with the columns below (past "e|", one character per bar line).
    final chordLine = List.filled(2 + lineBars * (barColumns + 1), ' ');
    for (var bar = 0; bar < lineBars; bar++) {
      for (var c = 0; c < barColumns; c++) {
        final name = over[(b + bar) * barColumns + c];
        if (name == null) continue;
        final at = 2 + bar * (barColumns + 1) + c;
        for (var d = 0; d < name.length && at + d < chordLine.length; d++) {
          chordLine[at + d] = name[d];
        }
      }
    }
    final chordText = chordLine.join().trimRight();
    if (chordText.isNotEmpty) out.writeln(chordText);
    for (var s = 0; s < 6; s++) {
      out.write('${names[s]}|');
      for (var bar = 0; bar < lineBars; bar++) {
        final from = (b + bar) * barColumns;
        out.write('${cells[s].sublist(from, from + barColumns).join()}|');
      }
      out.writeln();
    }
    out.writeln();
  }
  return '${out.toString().trimRight()}\n{end_of_tab}';
}
