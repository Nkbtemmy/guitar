/// A metronome run: the tempo of each bar, steady, or stepping up as a speed trainer does
/// (start slow, a few BPM faster every few bars, then hold at the goal).
class MetronomePlan {
  MetronomePlan(this.bars, {required this.beatsPerBar});

  /// [bpm] for about [seconds].
  factory MetronomePlan.steady({required int bpm, required int beatsPerBar, double seconds = 300}) {
    final count = (seconds / (beatsPerBar * 60 / bpm)).ceil();
    return MetronomePlan([for (var i = 0; i < count; i++) bpm], beatsPerBar: beatsPerBar);
  }

  /// From [from] BPM up to [to], [step] faster every [barsPerStep] bars; then [to] for about
  /// [holdSeconds].
  factory MetronomePlan.trainer({
    required int from,
    required int to,
    required int step,
    required int barsPerStep,
    required int beatsPerBar,
    double holdSeconds = 120,
  }) {
    final bars = <int>[];
    for (var bpm = from; bpm < to; bpm += step) {
      bars.addAll(List.filled(barsPerStep, bpm));
    }
    final hold = MetronomePlan.steady(bpm: to, beatsPerBar: beatsPerBar, seconds: holdSeconds);
    return MetronomePlan([...bars, ...hold.bars], beatsPerBar: beatsPerBar);
  }

  /// The tempo of each bar.
  final List<int> bars;
  final int beatsPerBar;

  /// When each bar starts, in seconds, and when the run ends.
  late final List<double> _starts = () {
    final starts = <double>[];
    var t = 0.0;
    for (final bpm in bars) {
      starts.add(t);
      t += beatsPerBar * 60 / bpm;
    }
    return [...starts, t];
  }();

  double get seconds => _starts.last;

  /// Where the run is [t] seconds in: the bar, its tempo, and the beat within it (0 = the
  /// accented one).
  ({int bar, int bpm, int beat}) at(double t) {
    var lo = 0, hi = bars.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_starts[mid] <= t) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final bpm = bars[lo];
    final beat = ((t - _starts[lo]) / (60 / bpm)).floor().clamp(0, beatsPerBar - 1);
    return (bar: lo, bpm: bpm, beat: beat);
  }
}

/// The tempo from taps on a button: the average gap between the last few, ignoring a pause
/// long enough to mean starting over.
class TapTempo {
  final _taps = <Duration>[];

  /// Records a tap at [at] (on any steady clock); the tempo so far, or null after one tap.
  int? tap(Duration at) {
    if (_taps.isNotEmpty && at - _taps.last > const Duration(seconds: 2)) _taps.clear();
    _taps.add(at);
    if (_taps.length > 5) _taps.removeAt(0);
    if (_taps.length < 2) return null;
    final gap = (_taps.last - _taps.first).inMicroseconds / (_taps.length - 1) / 1e6;
    return (60 / gap).round().clamp(30, 260);
  }
}
