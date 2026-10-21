import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../audio/analysis.dart';
import '../../audio/chord_matcher.dart';
import '../../audio/sound_player.dart';
import '../../curriculum/models.dart';
import '../../music/chord.dart';
import '../../practice/trackers.dart';
import '../lesson/steps.dart';
import '../theme.dart';
import '../widgets/chord_diagram.dart';
import '../widgets/listening.dart';
import '../widgets/listening_badge.dart';
import 'play_along.dart';

enum SongMode { wait, playAlong }

/// Plays through a song chart. Wait mode advances only when the right chord is strummed;
/// play-along keeps time with the metronome and scores each bar.
class SongView extends StatefulWidget {
  const SongView({super.key, required this.song, this.onDone, this.showHeader = true});

  final Song song;
  final StepDone? onDone;
  final bool showHeader;

  @override
  State<SongView> createState() => _SongViewState();
}

class _SongViewState extends State<SongView> with Listening, SingleTickerProviderStateMixin {
  late final AppServices _services = context.read<AppServices>();
  late final List<Chord> _bars = [for (final id in widget.song.bars) _services.library.byId(id)];
  late final Ticker _ticker = createTicker(_tick);
  SongMode _mode = SongMode.wait;
  double _tempo = 0.8;
  ChordVerdict? _verdict;
  late SequenceTracker<Chord> _wait = _newTracker();
  PlayAlongSession? _session;
  String? _result;

  SequenceTracker<Chord> _newTracker() => SequenceTracker<Chord>(targets: _bars, matcher: (f, c) => _verdict?.matches ?? false);

  int get _currentBar => _mode == SongMode.wait ? _wait.index : (_session?.currentBar ?? -1);

  @override
  void onFrame(AnalysisFrame f) {
    if (_mode == SongMode.playAlong) {
      _session?.onFrame(f);
      return;
    }
    final target = _wait.current;
    if (target == null) return;
    _verdict = f.hasSound ? _services.matcher.verify(f.peaks, target) : null;
    if (_wait.process(f)) {
      setState(() {});
      if (_wait.done) _finish(0.85, 'Song complete! Try play-along mode for 3 stars.');
    }
  }

  void _finish(double score, String message) {
    setState(() => _result = message);
    widget.onDone?.call(score);
  }

  void _setMode(SongMode mode) {
    _session?.stop();
    _ticker.stop();
    setState(() {
      _mode = mode;
      _session = null;
      _result = null;
      _wait = _newTracker();
    });
  }

  Future<void> _startPlayAlong() async {
    final session = PlayAlongSession(
      player: _services.player,
      matcher: _services.matcher,
      bpm: (widget.song.bpm * _tempo).round(),
      beatsPerBar: widget.song.beatsPerBar,
      barChords: _bars,
    );
    setState(() {
      _session = session;
      _result = null;
    });
    await session.start();
    if (!_ticker.isActive) _ticker.start();
  }

  void _tick(Duration _) {
    final s = _session;
    if (s == null) return;
    if (s.finished) {
      s.stop();
      _ticker.stop();
      // Full marks need full tempo; slower practice tops out at two stars.
      final accuracy = s.bars.accuracy;
      final score = _tempo >= 1.0 ? accuracy : accuracy * 0.85;
      setState(() => _session = null);
      _finish(score, 'You played ${(accuracy * 100).round()}% of the bars right${_tempo < 1 ? ' at ${(_tempo * 100).round()}% speed' : ''}.');
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _session?.stop();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final bar = _currentBar;
    final current = bar >= 0 && bar < _bars.length ? _bars[bar] : null;
    // Preview the next chord *change*, not a repeat of the current chord.
    final next = current == null ? null : _bars.skip(bar + 1).where((c) => c.id != current.id).firstOrNull;
    final s = _session;
    var barIndex = 0;
    return ListView(padding: const EdgeInsets.all(20), children: [
      if (widget.showHeader) ...[
        Text(song.title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        Text('${song.credit} · ${song.beatsPerBar}/4 · ${song.bpm} BPM · ${song.chordIds.map((c) => _services.library.byId(c).symbol).join(' ')}',
            style: const TextStyle(color: kMuted)),
        const SizedBox(height: 14),
      ],
      SegmentedButton<SongMode>(
        segments: const [
          ButtonSegment(value: SongMode.wait, icon: Icon(Icons.hourglass_bottom_rounded), label: Text('Wait mode')),
          ButtonSegment(value: SongMode.playAlong, icon: Icon(Icons.speed_rounded), label: Text('Play along')),
        ],
        selected: {_mode},
        onSelectionChanged: (v) => _setMode(v.first),
      ),
      const SizedBox(height: 14),
      SizedBox(
        height: 170,
        child: s != null && s.countIn > 0
            ? Center(child: Text('${s.countIn}', style: const TextStyle(fontSize: 88, fontWeight: FontWeight.w900, color: kAccent)))
            : current == null
                ? Center(
                    child: Text(_result ?? (_mode == SongMode.wait ? 'Done!' : 'Press start when ready'),
                        textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)))
                : Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    ChordDiagram(chord: current, width: 120, showName: true),
                    if (next != null) ...[
                      const SizedBox(width: 18),
                      Opacity(opacity: 0.5, child: ChordDiagram(chord: next, width: 66, showName: true)),
                    ],
                  ]),
      ),
      const SizedBox(height: 12),
      for (final line in song.lines) ...[
        Row(children: [
          for (final chordId in line.bars) _BarCell(symbol: _services.library.byId(chordId).symbol, index: barIndex++, current: bar),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 12, left: 4),
          child: Text(line.lyrics.isEmpty ? '♪' : line.lyrics, style: const TextStyle(fontSize: 16, color: kTextSoft)),
        ),
      ],
      if (_mode == SongMode.playAlong && s == null) ...[
        Row(children: [
          const Text('Tempo', style: TextStyle(color: kMuted)),
          Expanded(
            child: Slider(
              value: _tempo,
              min: 0.5,
              max: 1.0,
              divisions: 5,
              label: '${(song.bpm * _tempo).round()} BPM',
              onChanged: (v) => setState(() => _tempo = v),
            ),
          ),
          Text('${(song.bpm * _tempo).round()} BPM'),
        ]),
        FilledButton.icon(
          onPressed: _startPlayAlong,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(_result == null ? 'Start' : 'Play again'),
        ),
      ],
      if (_mode == SongMode.wait && _wait.done)
        OutlinedButton.icon(onPressed: () => _setMode(SongMode.wait), icon: const Icon(Icons.replay_rounded), label: const Text('Play again')),
      if (_result != null && current != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_result!)),
      const SizedBox(height: 10),
      if (s == null)
        Center(
          child: HearButton(
            label: 'Listen to the song',
            onPressed: () => _services.player.playSong(song, _services.library, bpm: (song.bpm * _tempo).round()),
          ),
        ),
      const SizedBox(height: 14),
      ListeningBadge(message: _mode == SongMode.wait ? 'Waiting for ${current?.symbol ?? '…'}' : null),
    ]);
  }
}

class _BarCell extends StatelessWidget {
  const _BarCell({required this.symbol, required this.index, required this.current});

  final String symbol;
  final int index, current;

  @override
  Widget build(BuildContext context) {
    final isCurrent = index == current;
    final done = current >= 0 && index < current;
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 44,
        margin: const EdgeInsets.only(right: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isCurrent ? kAccent : (done ? kSuccess.withValues(alpha: 0.15) : kSurfaceHigh),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(symbol,
            style: TextStyle(
                fontWeight: FontWeight.w800, fontSize: 17, color: isCurrent ? kOnAccent : (done ? kSuccess : null))),
      ),
    );
  }
}
