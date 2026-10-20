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
  }) : bars = BarScorer(
          bars: barChords.length,
          barSeconds: beatsPerBar * 60 / bpm,
          startSeconds: beatsPerBar * 60 / bpm,
        );

  final SoundPlayer player;
  final ChordMatcher matcher;
  final int bpm, beatsPerBar;
  final List<Chord> barChords;
  final BarScorer bars;
  final onsets = <double>[];
  final _clock = Stopwatch();

  double get beatSeconds => 60 / bpm;
  double get seconds => _clock.elapsedMicroseconds / 1e6;
  double get totalSeconds => (barChords.length + 1) * beatsPerBar * beatSeconds;
  bool get running => _clock.isRunning;
  bool get finished => running && seconds >= totalSeconds + 0.3;

  /// Bar being played now, or -1 during the count-in and after the end.
  int get currentBar => running ? bars.barAt(seconds) : -1;

  /// Beat number within the count-in (1-based), or 0 once the song has started.
  int get countIn {
    if (!running || seconds >= beatsPerBar * beatSeconds) return 0;
    return (seconds / beatSeconds).floor() + 1;
  }

  /// Eighth-note slot within the current bar (for highlighting strum patterns).
  int get eighthInBar {
    final rel = seconds - beatsPerBar * beatSeconds;
    if (rel < 0) return -1;
    return ((rel / (beatSeconds / 2)).floor()) % (beatsPerBar * 2);
  }

  Future<void> start() async {
    onsets.clear();
    await player.playClickTrack(bpm: bpm, beatsPerBar: beatsPerBar, bars: barChords.length + 1);
    _clock
      ..reset()
      ..start();
  }

  void onFrame(AnalysisFrame f) {
    if (!running) return;
    // Frames arrive just after they were captured; place them on the session clock.
    final now = seconds;
    for (final o in f.onsets) {
      onsets.add(now - (f.time - o));
    }
    final bar = bars.barAt(now);
    if (bar >= 0 && f.hasSound) bars.record(now, matcher.verify(f.peaks, barChords[bar]).matches);
  }

  void stop() {
    _clock.stop();
    player.stop();
  }
}
