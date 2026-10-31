import '../../audio/analysis.dart';
import '../../audio/chord_matcher.dart';
import '../../audio/sound_player.dart';
import '../../music/chord.dart';
import '../../practice/trackers.dart';

/// A timed run: one count-in bar of clicks, then [barChords] bars. Collects strum onsets and
/// per-bar chord accuracy on a clock that starts with the click track.
class PlayAlongSession {
  PlayAlongSession({
    required this.player,
    required this.matcher,
    required this.bpm,
    required this.beatsPerBar,
    required this.barChords,
    this.backing,
  }) : bars = BarScorer(
          bars: barChords.length,
          barSeconds: beatsPerBar * 60 / bpm,
          startSeconds: beatsPerBar * 60 / bpm,
        );

  final SoundPlayer player;
  final ChordMatcher matcher;
  final int bpm, beatsPerBar;
  final List<Chord> barChords;

  /// When set, the song is strummed along with the clicks: a cache key and the strum pattern.
  final ({String key, StrumPattern strum})? backing;
  final BarScorer bars;

  /// Strum onsets on the session clock.
  final onsets = <double>[];
  final _clock = Stopwatch();
  final _stream = StreamClock();
  // The same onsets in stream time, and the level of every frame heard, to measure accents.
  final _streamOnsets = <double>[];
  final _levels = <(double, double)>[];

  double get beatSeconds => 60 / bpm;
  double get seconds => _clock.elapsedMicroseconds / 1e6;
  double get totalSeconds => (barChords.length + 1) * beatsPerBar * beatSeconds;
  bool get running => _clock.isRunning;
  bool get finished => running && seconds >= totalSeconds + 0.3;

  /// Bar being played now, or -1 during the count-in and after the end.
  int get currentBar => running ? bars.barAt(seconds) : -1;

  /// How far through the current bar the song is (0..1), or 0 during the count-in.
  double get barProgress {
    final rel = seconds - bars.startSeconds;
    return rel < 0 ? 0 : (rel % bars.barSeconds) / bars.barSeconds;
  }

  /// Beat number within the count-in (1-based), or 0 once the song has started.
  int get countIn {
    if (!running || seconds >= beatsPerBar * beatSeconds) return 0;
    return (seconds / beatSeconds).floor() + 1;
  }

  /// The slot of [pattern] being played now (for highlighting it), or -1 during the count-in.
  int slotOf(StrumPattern pattern) {
    final rel = seconds - beatsPerBar * beatSeconds;
    if (rel < 0) return -1;
    return pattern.slotAt((rel / beatSeconds) % beatsPerBar);
  }

  /// How loud each of [onsets] was.
  List<double> get onsetLevels => strumLevels(_streamOnsets, _levels);

  Future<void> start() async {
    onsets.clear();
    _streamOnsets.clear();
    _levels.clear();
    final b = backing;
    if (b == null) {
      await player.playClickTrack(bpm: bpm, beatsPerBar: beatsPerBar, bars: barChords.length + 1);
    } else {
      await player.playAlongTrack(key: b.key, bars: barChords, strum: b.strum, bpm: bpm);
    }
    _clock
      ..reset()
      ..start();
  }

  void onFrame(AnalysisFrame f) {
    if (!running) return;
    // Frames arrive a jittery while after they were captured; place them on the session clock.
    final now = seconds;
    _stream.observe(f.time, now);
    _levels.add((f.time, f.rms));
    for (final o in f.onsets) {
      onsets.add(_stream.toLocal(o));
      _streamOnsets.add(o);
    }
    final bar = bars.barAt(now);
    if (bar >= 0 && f.hasSound) bars.record(now, matcher.verify(f.peaks, barChords[bar]).matches);
  }

  void stop() {
    _clock.stop();
    player.stop();
  }
}
