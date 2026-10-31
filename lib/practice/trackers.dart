import 'dart:math' as math;

import '../audio/analysis.dart';

typedef FrameMatcher<T> = bool Function(AnalysisFrame frame, T target);

/// Walks through [targets] one at a time. Each success needs a fresh pick attack (onset) followed
/// by [requiredFrames] matching frames, so repeated notes or chords must really be played again.
/// If an attack is missed, holding a *different* target steadily for [sustainSeconds] also counts.
class SequenceTracker<T> {
  SequenceTracker({
    required this.targets,
    required this.matcher,
    this.requiredFrames = 2,
    this.windowSeconds = 0.7,
    this.sustainSeconds = 0.8,
  });

  final List<T> targets;
  final FrameMatcher<T> matcher;
  final int requiredFrames;
  final double windowSeconds, sustainSeconds;

  int index = 0;
  double? _armedAt;
  int _hits = 0;
  double? _sustainStart;

  bool get done => index >= targets.length;
  T? get current => done ? null : targets[index];
  double get progress => targets.isEmpty ? 1 : index / targets.length;

  void reset() {
    index = 0;
    _armedAt = null;
    _hits = 0;
    _sustainStart = null;
  }

  /// Moves to target [i]: back to try a part again, or ahead to skip it.
  void jumpTo(int i) {
    reset();
    index = i.clamp(0, targets.length);
  }

  /// Returns true when this frame completed the current target.
  bool process(AnalysisFrame frame) {
    if (done) return false;
    if (frame.onsets.isNotEmpty) {
      _armedAt = frame.onsets.last;
      _hits = 0;
    }
    final target = targets[index];
    final match = frame.hasSound && matcher(frame, target);

    final canSustain = index == 0 || targets[index - 1] != target;
    if (match && canSustain) {
      _sustainStart ??= frame.time;
      if (frame.time - _sustainStart! >= sustainSeconds) return _advance();
    } else {
      _sustainStart = null;
    }

    if (_armedAt == null) return false;
    if (frame.time - _armedAt! > windowSeconds) {
      _armedAt = null;
      return false;
    }
    if (match && ++_hits >= requiredFrames) return _advance();
    return false;
  }

  bool _advance() {
    index++;
    _armedAt = null;
    _hits = 0;
    _sustainStart = null;
    return true;
  }
}

enum StrumDirection { down, up }

class StrumHit {
  const StrumHit(this.slot, this.direction, {this.muted = false, this.accent = false});

  /// Position in the bar, counted in the pattern's slots (eighths, or sixteenths) from 0.
  final int slot;
  final StrumDirection direction;

  /// A muted, percussive strum (a "chuck"): the strings are slapped and stopped, no chord rings.
  final bool muted;

  /// Played louder than the strums around it.
  final bool accent;
}

/// A one-bar strum pattern with two slots a beat (eighths) or four (sixteenths): 'D' down, 'U'
/// up, 'X' a muted strum (a "chuck"), '-' rest. "D-DU-UDU" is the folk pattern. [accents] marks
/// the strums to play louder with a '>' in the same slot. With [swing], the second eighth of each
/// beat comes late, two thirds of the way through it: the long-short feel of a shuffle.
class StrumPattern {
  StrumPattern(this.source, this.beatsPerBar, {this.accents = '', this.swing = false})
      : assert(source.length == beatsPerBar * 2 || source.length == beatsPerBar * 4,
            'pattern must have two or four slots per beat'),
        assert(accents.isEmpty || accents.length == source.length, 'accents must line up with the pattern'),
        assert(!swing || source.length == beatsPerBar * 2, 'swing is for eighth-note patterns'),
        hits = [
          for (var i = 0; i < source.length; i++)
            if (source[i] == 'D' || source[i] == 'U' || source[i] == 'X')
              StrumHit(i, source[i] == 'U' ? StrumDirection.up : StrumDirection.down,
                  muted: source[i] == 'X', accent: i < accents.length && accents[i] == '>'),
        ];

  final String source, accents;
  final int beatsPerBar;
  final bool swing;
  final List<StrumHit> hits;

  int get slotsPerBeat => source.length ~/ beatsPerBar;
  bool get hasAccents => hits.any((h) => h.accent);

  /// Tells patterns apart that sound different: same strokes, other accents or swing.
  String get key => '$source${accents.isEmpty ? '' : '/$accents'}${swing ? '/swing' : ''}';

  /// Where [slot] falls in the bar, in beats.
  double beatOf(int slot) {
    final part = slot % slotsPerBeat;
    return slot ~/ slotsPerBeat + (swing && part == 1 ? 2 / 3 : part / slotsPerBeat);
  }

  /// The slot being played [beats] into the bar.
  int slotAt(double beats) {
    final beat = beats.floor();
    final within = beats - beat;
    final part = swing ? (within < 2 / 3 ? 0 : 1) : (within * slotsPerBeat).floor();
    return (beat % beatsPerBar) * slotsPerBeat + part;
  }

  /// How far (seconds) a strum may land from its time and still count: under half the shortest
  /// gap between slots, so neighbouring sixteenths can't be mistaken for each other.
  double tolerance(int bpm) => math.min(0.11, 0.45 * 60 / bpm * (swing ? 1 / 3 : 1 / slotsPerBeat));

  /// Expected strum times in seconds for [bars] bars, after a one-bar count-in.
  List<double> expectedTimes({required int bpm, required int bars}) {
    final beat = 60 / bpm;
    final start = beatsPerBar * beat;
    return [
      for (var b = 0; b < bars; b++)
        for (final h in hits) start + (b * beatsPerBar + beatOf(h.slot)) * beat,
    ];
  }
}

class TimingResult {
  const TimingResult({required this.hit, required this.offset, required this.extra, this.matched = const []});

  /// One entry per expected strum.
  final List<bool> hit;

  /// Estimated constant latency that was compensated, in seconds.
  final double offset;

  /// Onsets that matched nothing.
  final int extra;

  /// For each expected strum, the index of the onset that matched it (null when missed).
  final List<int?> matched;

  int get hits => hit.where((h) => h).length;
  double get accuracy => hit.isEmpty ? 0 : hits / hit.length;
}

class TimingScorer {
  /// Matches detected [onsets] to [expected] strum times. A constant offset (audio latency) is
  /// estimated as the median of nearest-onset differences and removed before matching.
  static TimingResult score(List<double> expected, List<double> onsets,
      {double tolerance = 0.11, double maxOffset = 0.25}) {
    final diffs = <double>[];
    for (final e in expected) {
      double? best;
      for (final o in onsets) {
        final d = o - e;
        if (d.abs() <= maxOffset && (best == null || d.abs() < best.abs())) best = d;
      }
      if (best != null) diffs.add(best);
    }
    diffs.sort();
    final offset = diffs.isEmpty ? 0.0 : diffs[diffs.length ~/ 2];

    final used = List<bool>.filled(onsets.length, false);
    final matched = <int?>[];
    for (final e in expected) {
      var bestIdx = -1;
      var bestDist = tolerance;
      for (var i = 0; i < onsets.length; i++) {
        if (used[i]) continue;
        final d = (onsets[i] - offset - e).abs();
        if (d <= bestDist) {
          bestDist = d;
          bestIdx = i;
        }
      }
      if (bestIdx >= 0) used[bestIdx] = true;
      matched.add(bestIdx >= 0 ? bestIdx : null);
    }
    return TimingResult(
      hit: [for (final m in matched) m != null],
      offset: offset,
      extra: used.where((u) => !u).length,
      matched: matched,
    );
  }
}

/// How loud each of [onsets] was: the peak of [levels] ((time, rms) per analysis frame) in
/// the moment after it, when the strum rings loudest.
List<double> strumLevels(List<double> onsets, List<(double, double)> levels) => [
      for (final o in onsets) levels.where((l) => l.$1 > o && l.$1 <= o + 0.15).fold(0.0, (m, l) => math.max(m, l.$2)),
    ];

/// How much louder the accented strums were played than the plain ones.
class AccentResult {
  const AccentResult(this.ratio);

  /// The accented strums' average level over the plain ones' (1: no difference).
  final double ratio;

  /// 0..1, full marks from a third louder (about 2.5 dB): clearly heard, without banging.
  double get score => ((ratio - 1) / 0.33).clamp(0.0, 1.0);

  /// Compares the accented strums of [pattern] with plain ones in the same direction (a down
  /// strum is louder than an up anyway), from the [levels] of the onsets [timing] matched to
  /// them. Null when there's nothing to compare.
  static AccentResult? of(StrumPattern pattern, TimingResult timing, List<double> levels) {
    final accented = <StrumDirection, List<double>>{}, plain = <StrumDirection, List<double>>{};
    for (var i = 0; i < timing.matched.length; i++) {
      final onset = timing.matched[i];
      final hit = pattern.hits[i % pattern.hits.length];
      if (onset == null || hit.muted) continue;
      (hit.accent ? accented : plain).putIfAbsent(hit.direction, () => []).add(levels[onset]);
    }
    double mean(List<double> v) => v.reduce((a, b) => a + b) / v.length;
    var ratio = 0.0, weight = 0;
    for (final MapEntry(key: direction, value: loud) in accented.entries) {
      final soft = plain[direction];
      if (soft == null) continue;
      final m = mean(soft);
      if (m <= 0) continue;
      ratio += mean(loud) / m * loud.length;
      weight += loud.length;
    }
    return weight == 0 ? null : AccentResult(ratio / weight);
  }
}

/// Maps stream time (seconds of audio captured, like [AnalysisFrame.time]) onto a local clock.
/// Frames arrive late by a delay that jitters: a frame can wait in the recorder's chunk for tens
/// of milliseconds, then for the UI thread. Every hold-up only adds, so the smallest gap between
/// the two clocks seen so far is the steady part of the delay, free of that jitter.
class StreamClock {
  double? _lag, _lastStream;

  /// Records that the frame ending at [streamTime] arrived at [localTime].
  void observe(double streamTime, double localTime) {
    // The stream restarted (the mic was reopened), so the old gap no longer holds.
    if (_lastStream != null && streamTime < _lastStream!) _lag = null;
    _lastStream = streamTime;
    final lag = localTime - streamTime;
    if (_lag == null || lag < _lag!) _lag = lag;
  }

  /// [streamTime] on the local clock.
  double toLocal(double streamTime) => streamTime + (_lag ?? 0);
}

/// Collects per-bar chord accuracy during a timed play-along.
class BarScorer {
  BarScorer({required this.bars, required this.barSeconds, required this.startSeconds, this.graceFraction = 0.25});

  final int bars;
  final double barSeconds, startSeconds, graceFraction;
  late final List<int> _good = List.filled(bars, 0);
  late final List<int> _total = List.filled(bars, 0);

  /// Bar index at [t] (seconds on the play-along clock), or -1 outside the song.
  int barAt(double t) {
    final rel = t - startSeconds;
    if (rel < 0) return -1;
    final b = rel ~/ barSeconds;
    return b < bars ? b : -1;
  }

  /// Records whether the expected chord was heard at time [t]. The first part of each bar is
  /// skipped to give time for the chord change.
  void record(double t, bool correct) {
    final b = barAt(t);
    if (b < 0) return;
    final into = (t - startSeconds) - b * barSeconds;
    if (into < graceFraction * barSeconds) return;
    _total[b]++;
    if (correct) _good[b]++;
  }

  bool barCorrect(int bar) => _total[bar] > 0 && _good[bar] / _total[bar] >= 0.3;

  double get accuracy => bars == 0 ? 0 : List.generate(bars, barCorrect).where((ok) => ok).length / bars;
}

/// Decides when a play-along should take the learner back: after [misses] parts (bars, or
/// notes) missed in a row. It goes back to the same place at most [tries] times, so a part
/// that's too hard can't trap them: after that the music carries on to the end.
class Rewinder {
  Rewinder({this.misses = 2, this.tries = 3});

  final int misses, tries;
  int _streak = 0;
  final _backTo = <int, int>{};

  /// How far back to go, in seconds.
  static const seconds = 10.0;

  /// Records how a part went; true when it's time to go back.
  bool record(bool right) {
    _streak = right ? 0 : _streak + 1;
    return _streak >= misses;
  }

  /// Whether to go back to [place] (counted if so). Either way the miss streak starts again.
  bool back(int place) {
    _streak = 0;
    final n = (_backTo[place] ?? 0) + 1;
    if (n > tries) return false;
    _backTo[place] = n;
    return true;
  }

  /// A fresh run: nothing missed yet, nowhere gone back to.
  void reset() {
    _streak = 0;
    _backTo.clear();
  }
}

/// Judges the notes of a timed play-along as the music passes them. A note counts as played
/// right when it's heard from a little before it's due until it stops ringing (the next note,
/// or [longest] beats); once that has passed with nothing heard, it's missed.
class NoteJudge {
  NoteJudge({required this.beats, required this.notes, required this.matches, this.longest = 1.5})
      : results = List.filled(beats.length, null);

  /// When each note is due, in beats, in order.
  final List<double> beats;

  /// What each note sounds as (a chord column has several; any of them counts).
  final List<List<int>> notes;
  final bool Function(AnalysisFrame frame, int midi) matches;
  final double longest;

  /// Right, missed, or null (not judged yet), by note.
  final List<bool?> results;

  /// Seconds a beat lasts at the tempo playing now.
  double secondsPerBeat = 0.5;

  /// How early a note may come, and how long it stays open at least, in seconds.
  static const early = 0.15, shortest = 0.35;

  int _next = 0;

  double _opens(int i) => beats[i] - early / secondsPerBeat;

  double _closes(int i) {
    final next = i + 1 < beats.length ? beats[i + 1] : double.infinity;
    final end = next < beats[i] + longest ? next : beats[i] + longest;
    final atLeast = beats[i] + shortest / secondsPerBeat;
    return end > atLeast ? end : atLeast;
  }

  /// A frame heard at [beat]: marks the open notes it plays as right.
  void hear(double beat, AnalysisFrame frame) {
    for (var i = _next; i < beats.length && _opens(i) <= beat; i++) {
      if (results[i] == null && beat <= _closes(i) && notes[i].any((m) => matches(frame, m))) results[i] = true;
    }
  }

  /// Closes the notes whose time has passed by [beat] (up to note [last]), marking the ones not
  /// heard as missed. Returns them, in order.
  List<int> judgeUpTo(double beat, {int? last}) {
    final closed = <int>[];
    final end = last == null ? beats.length : last + 1;
    while (_next < end && _closes(_next) < beat) {
      results[_next] ??= false;
      closed.add(_next++);
    }
    return closed;
  }

  /// Playing again from note [i]: it and everything after are to be judged afresh.
  void restartAt(int i) {
    _next = i;
    results.fillRange(i, results.length, null);
  }
}

/// Notices a wrong note: a fresh pluck whose pitch comes through clearly as something other
/// than the note wanted. Only plucks after [reset] count, so the note just played, still ringing,
/// isn't taken for a wrong try at the next one.
class WrongNote {
  double? _pluck;
  int _frames = 0;

  /// Clear frames of a wrong pitch it takes, soon after the pluck.
  static const frames = 2;

  void reset() {
    _pluck = null;
    _frames = 0;
  }

  /// True once [frame] confirms a wrong note; [right] says whether a frame plays the wanted note.
  bool hear(AnalysisFrame frame, bool Function(AnalysisFrame) right) {
    if (frame.onsets.isNotEmpty) {
      _pluck = frame.onsets.last;
      _frames = 0;
    }
    final pluck = _pluck;
    if (pluck == null || frame.time - pluck > 0.6) return false;
    final pitch = frame.pitch;
    if (pitch == null || pitch.clarity < 0.85 || right(frame)) return false;
    return ++_frames >= frames;
  }
}

/// A song's bars grouped into its lines (as the chart shows them), for going back a line.
class SongLines {
  SongLines(List<int> barsPerLine) {
    var bar = 0;
    for (final n in barsPerLine) {
      if (n <= 0) continue;
      _starts.add(bar);
      bar += n;
    }
    if (_starts.isEmpty) _starts.add(0);
    _starts.add(bar);
  }

  /// First bar of each line, then the total.
  final _starts = <int>[];

  int get bars => _starts.last;

  int _line(int bar) {
    var i = 0;
    while (i + 2 < _starts.length && _starts[i + 1] <= bar) {
      i++;
    }
    return i;
  }

  /// First bar of the line holding [bar].
  int startOf(int bar) => _starts[_line(bar)];

  /// One past the last bar of the line holding [bar].
  int endOf(int bar) => _starts[_line(bar) + 1];

  /// Where "back" goes while [bar] plays, [into] of the way through it (0..1): the start of this
  /// line, or of the line before when this one has only just begun.
  int back(int bar, double into) {
    final line = _line(bar);
    final start = _starts[line];
    if (bar == start && into < 0.5 && line > 0) return _starts[line - 1];
    return start;
  }
}

int starsFor(double score) => score >= 0.9 ? 3 : (score >= 0.7 ? 2 : 1);
