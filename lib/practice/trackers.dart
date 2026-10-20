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
  const StrumHit(this.eighth, this.direction);

  /// Position in the bar, counted in eighth notes from 0.
  final int eighth;
  final StrumDirection direction;
}

/// A one-bar strum pattern in eighth notes: 'D' down, 'U' up, '-' rest. "D-DU-UDU" is the folk pattern.
class StrumPattern {
  StrumPattern(this.source, this.beatsPerBar)
      : assert(source.length == beatsPerBar * 2, 'pattern must have two slots per beat'),
        hits = [
          for (var i = 0; i < source.length; i++)
            if (source[i] == 'D' || source[i] == 'U')
              StrumHit(i, source[i] == 'D' ? StrumDirection.down : StrumDirection.up),
        ];

  final String source;
  final int beatsPerBar;
  final List<StrumHit> hits;

  /// Expected strum times in seconds for [bars] bars, after a one-bar count-in.
  List<double> expectedTimes({required int bpm, required int bars}) {
    final beat = 60 / bpm;
    final start = beatsPerBar * beat;
    return [
      for (var b = 0; b < bars; b++)
        for (final h in hits) start + (b * beatsPerBar + h.eighth / 2) * beat,
    ];
  }
}

class TimingResult {
  const TimingResult({required this.hit, required this.offset, required this.extra});

  /// One entry per expected strum.
  final List<bool> hit;

  /// Estimated constant latency that was compensated, in seconds.
  final double offset;

  /// Onsets that matched nothing.
  final int extra;

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
    final hit = <bool>[];
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
      hit.add(bestIdx >= 0);
    }
    return TimingResult(hit: hit, offset: offset, extra: used.where((u) => !u).length);
  }
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

int starsFor(double score) => score >= 0.9 ? 3 : (score >= 0.7 ? 2 : 1);
