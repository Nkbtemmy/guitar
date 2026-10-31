import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../audio/analysis.dart';
import '../../audio/chord_matcher.dart';
import '../../music/chord.dart';
import '../../practice/trackers.dart';
import '../../progress/practice_log.dart';
import '../theme.dart';
import '../widgets/chord_view.dart';
import '../widgets/listening.dart';
import '../widgets/listening_badge.dart';

/// Chords a beginner changes between, offered as the challenge's pairs.
const challengeChords = ['Em', 'E', 'Am', 'A', 'D', 'G', 'C', 'Dm', 'E7', 'A7', 'D7', 'G7', 'B7', 'Fmaj7', 'F'];

/// Pairs worth drilling, roughly in the order a beginner meets them.
const suggestedPairs = [('Em', 'Am'), ('A', 'D'), ('D', 'G'), ('C', 'G'), ('G', 'Em'), ('C', 'Am'), ('A', 'E'), ('Am', 'Dm'), ('C', 'F')];

enum _Phase { setup, countdown, running, done }

/// One-minute changes: switch between two chords as many times as you can in a minute, strumming
/// each once, cleanly. The best for each pair is kept, and how it has grown.
class ChordChallengeScreen extends StatefulWidget {
  const ChordChallengeScreen({super.key, this.pair, this.length = const Duration(minutes: 1)});

  /// The chords to start on; the last pair practised otherwise.
  final (String, String)? pair;
  final Duration length;

  @override
  State<ChordChallengeScreen> createState() => _ChordChallengeScreenState();
}

class _ChordChallengeScreenState extends State<ChordChallengeScreen> with SingleTickerProviderStateMixin {
  late final AppServices _services = context.read<AppServices>();
  late final Ticker _ticker = createTicker(_tick);
  late final (String, String) _first = widget.pair ?? context.read<PracticeLog>().lastChangePair ?? ('C', 'G');
  late String _a = _first.$1, _b = _first.$2;
  _Phase _phase = _Phase.setup;
  Duration _elapsed = Duration.zero;
  SequenceTracker<Chord>? _tracker;
  ChordVerdict? _verdict;
  int _count = 0;
  bool _newBest = false;

  static const _countdown = Duration(seconds: 3);

  Chord _chord(String id) => _services.library.byId(id);

  void _pick(String a, String b) => setState(() {
        _a = a;
        _b = b;
      });

  void _start() {
    final a = _chord(_a), b = _chord(_b);
    _verdict = null;
    _tracker = SequenceTracker<Chord>(
      // More than anyone plays in a minute: it never runs out.
      targets: [for (var i = 0; i < 400; i++) i.isEven ? a : b],
      matcher: (f, c) => _verdict?.matches ?? false,
    );
    setState(() {
      _phase = _Phase.countdown;
      _elapsed = Duration.zero;
      _count = 0;
    });
    _ticker
      ..stop()
      ..start();
  }

  void _tick(Duration elapsed) {
    final phase = elapsed < _countdown ? _Phase.countdown : _Phase.running;
    if (elapsed >= _countdown + widget.length) {
      _ticker.stop();
      final best = context.read<PracticeLog>().recordChanges(_a, _b, _count);
      setState(() {
        _phase = _Phase.done;
        _newBest = best;
      });
      return;
    }
    // Redraw only when the seconds shown change.
    if (phase != _phase || elapsed.inSeconds != _elapsed.inSeconds) {
      setState(() {
        _phase = phase;
        _elapsed = elapsed;
      });
    }
  }

  void _hear(AnalysisFrame f) {
    final tracker = _tracker;
    final target = tracker?.current;
    if (_phase != _Phase.running || tracker == null || target == null) return;
    _verdict = f.hasSound ? _services.matcher.verify(f.peaks, target) : null;
    // The first chord just starts things off: every one after it is a change.
    if (tracker.process(f)) setState(() => _count = math.max(0, tracker.index - 1));
  }

  void _stop() {
    _ticker.stop();
    setState(() => _phase = _Phase.setup);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final log = context.watch<PracticeLog>();
    final runs = log.changeRuns(_a, _b);
    final best = log.bestChanges(_a, _b);
    return Scaffold(
      appBar: AppBar(title: const Text('Chord changes')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          switch (_phase) {
            _Phase.setup => _setup(best, runs),
            _Phase.countdown => _countdownView(),
            _Phase.running => _runningView(),
            _Phase.done => _doneView(best, runs),
          },
          if (_phase == _Phase.countdown || _phase == _Phase.running) ...[
            const SizedBox(height: 16),
            FrameListener(onFrame: _hear),
            const ListeningBadge(),
            const SizedBox(height: 12),
            Center(child: TextButton(onPressed: _stop, child: const Text('Stop'))),
          ],
        ]),
      ),
    );
  }

  Widget _setup(int? best, List<ChangeRun> runs) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text(
          'Switch between two chords as many times as you can in one minute. Strum each chord once, '
          'cleanly, then change. Count goes up only when the new chord rings true.',
          style: TextStyle(fontSize: 16, height: 1.4),
        ),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: _ChordPicker(value: _a, onChanged: (v) => setState(() => _a = v))),
          IconButton(
            tooltip: 'Swap',
            onPressed: () => _pick(_b, _a),
            icon: const Icon(Icons.swap_horiz_rounded),
          ),
          Expanded(child: _ChordPicker(value: _b, onChanged: (v) => setState(() => _b = v))),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final (a, b) in suggestedPairs)
            ChoiceChip(
              label: Text('$a – $b'),
              selected: PracticeLog.pairKey(a, b) == PracticeLog.pairKey(_a, _b),
              onSelected: (_) => _pick(a, b),
            ),
        ]),
        const SizedBox(height: 18),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          ChordView(chord: _chord(_a), width: 100, compact: true),
          const SizedBox(width: 24),
          ChordView(chord: _chord(_b), width: 100, compact: true),
        ]),
        const SizedBox(height: 18),
        _History(runs: runs, best: best),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _a == _b ? null : _start,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text('Start: ${widget.length.inSeconds} seconds'),
        ),
      ]);

  Widget _countdownView() => SizedBox(
        height: 300,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Get ready', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            Text('${(_countdown - _elapsed).inSeconds.clamp(0, 3) + 1}',
                style: const TextStyle(fontSize: 96, fontWeight: FontWeight.w900, color: kAccent)),
            Text('Start on $_a', style: const TextStyle(color: kMuted)),
          ]),
        ),
      );

  Widget _runningView() {
    final left = _countdown + widget.length - _elapsed;
    final target = _tracker?.current;
    final next = target == null ? null : _chord(target.id == _a ? _b : _a);
    return Column(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(
          value: 1 - left.inMilliseconds / widget.length.inMilliseconds,
          minHeight: 10,
          backgroundColor: kSurfaceHigh,
        ),
      ),
      const SizedBox(height: 6),
      Text('${left.inSeconds.clamp(0, widget.length.inSeconds)} s left', style: const TextStyle(color: kMuted)),
      Text('$_count', style: const TextStyle(fontSize: 88, fontWeight: FontWeight.w900, height: 1.1)),
      const Text('changes', style: TextStyle(color: kMuted, fontWeight: FontWeight.w700)),
      const SizedBox(height: 14),
      if (target != null)
        // Shrinks to fit a small phone rather than overflow.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            ChordView(chord: target, width: 120),
            const SizedBox(width: 18),
            Opacity(opacity: 0.5, child: ChordView(chord: next!, width: 64, compact: true)),
          ]),
        ),
    ]);
  }

  Widget _doneView(int? best, List<ChangeRun> runs) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: 12),
        Icon(_newBest ? Icons.emoji_events_rounded : Icons.check_circle_rounded, size: 72, color: _newBest ? kAccent : kSuccess),
        Text('$_count changes', textAlign: TextAlign.center, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
        Text(_newBest ? 'A new personal best for $_a – $_b!' : 'Your best for $_a – $_b is ${best ?? 0}.',
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 18),
        _History(runs: runs, best: best),
        const SizedBox(height: 18),
        FilledButton.icon(onPressed: _start, icon: const Icon(Icons.replay_rounded), label: const Text('Again')),
        TextButton(onPressed: () => setState(() => _phase = _Phase.setup), child: const Text('Pick other chords')),
      ]);
}

class _ChordPicker extends StatelessWidget {
  const _ChordPicker({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
        // Keyed by the chord, so picking a suggested pair shows here too.
        key: ValueKey(value),
        initialValue: value,
        decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
        items: [for (final id in challengeChords) DropdownMenuItem(value: id, child: Text(id))],
        onChanged: (v) => v == null ? null : onChanged(v),
      );
}

/// The last minutes as bars, so the learner sees the count climb.
class _History extends StatelessWidget {
  const _History({required this.runs, required this.best});

  final List<ChangeRun> runs;
  final int? best;

  @override
  Widget build(BuildContext context) {
    if (runs.isEmpty) {
      return const Text('No minutes yet for this pair.', textAlign: TextAlign.center, style: TextStyle(color: kMuted));
    }
    final shown = runs.length > 12 ? runs.sublist(runs.length - 12) : runs;
    final top = math.max(1, best ?? 1);
    return Column(children: [
      Text('Best ${best ?? 0} · last ${runs.last.count} · ${runs.length} minute${runs.length == 1 ? '' : 's'} so far',
          style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      SizedBox(
        height: 70,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final r in shown)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Tooltip(
                  message: '${r.count} changes',
                  child: Container(
                    height: 6 + 64 * r.count / top,
                    decoration: BoxDecoration(
                      color: r.count == best ? kAccent : kAccentSoft.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    ]);
  }
}
