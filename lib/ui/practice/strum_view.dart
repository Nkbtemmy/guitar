import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../audio/analysis.dart';
import '../../curriculum/models.dart';
import '../../practice/trackers.dart';
import '../lesson/steps.dart';
import '../theme.dart';
import '../widgets/chord_diagram.dart';
import '../widgets/listening.dart';
import '../widgets/listening_badge.dart';
import 'play_along.dart';

/// Strum a pattern in time with the metronome; scored on timing and on holding the right chord.
class StrumView extends StatefulWidget {
  const StrumView({super.key, required this.step, required this.onDone});

  final StrumStep step;
  final StepDone onDone;

  @override
  State<StrumView> createState() => _StrumViewState();
}

class _StrumViewState extends State<StrumView> with Listening, SingleTickerProviderStateMixin {
  late final AppServices _services = context.read<AppServices>();
  late final Ticker _ticker = createTicker(_tick);
  PlayAlongSession? _session;
  ({double timing, double chords, double score})? _result;

  StrumStep get step => widget.step;

  @override
  void onFrame(AnalysisFrame f) => _session?.onFrame(f);

  Future<void> _start() async {
    final session = PlayAlongSession(
      player: _services.player,
      matcher: _services.matcher,
      bpm: step.bpm,
      beatsPerBar: step.beatsPerBar,
      barChords: [for (var b = 0; b < step.bars; b++) _services.library.byId(step.chordForBar(b))],
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
      final expected = step.strumPattern.expectedTimes(bpm: step.bpm, bars: step.bars);
      final timing = TimingScorer.score(expected, s.onsets).accuracy;
      final chords = s.bars.accuracy;
      final score = 0.6 * timing + 0.4 * chords;
      setState(() {
        _result = (timing: timing, chords: chords, score: score);
        _session = null;
      });
      widget.onDone(score);
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
    final s = _session;
    final bar = s?.currentBar ?? -1;
    final chordId = step.chordForBar(bar < 0 ? 0 : bar);
    final nextId = step.chordForBar(bar < 0 ? 0 : bar + 1);
    final chord = _services.library.byId(chordId);
    final next = _services.library.byId(nextId);
    final pattern = step.strumPattern;
    return ListView(padding: const EdgeInsets.all(20), children: [
      StepTitle('Strum in time',
          body: '${step.body ?? 'Follow the pattern with the metronome.'}\n${step.bpm} BPM · ${step.bars} bars · '
              '${step.chordIds.map((c) => _services.library.byId(c).symbol).join(' → ')}'),
      const SizedBox(height: 18),
      _PatternRow(pattern: pattern, active: s == null ? -1 : s.eighthInBar),
      const SizedBox(height: 18),
      SizedBox(
        height: 190,
        child: s != null && s.countIn > 0
            ? Center(
                child: Text('${s.countIn}',
                    style: const TextStyle(fontSize: 96, fontWeight: FontWeight.w900, color: kAccent)))
            : Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                ChordDiagram(chord: chord, width: 130, showName: true),
                if (next.id != chord.id) ...[
                  const SizedBox(width: 18),
                  Opacity(opacity: 0.5, child: ChordDiagram(chord: next, width: 70, showName: true)),
                ],
              ]),
      ),
      const SizedBox(height: 8),
      if (s != null)
        LinearProgressIndicator(value: (s.seconds / s.totalSeconds).clamp(0.0, 1.0), color: kAccent, backgroundColor: kSurfaceHigh),
      if (_result != null) _ResultCard(timing: _result!.timing, chords: _result!.chords, score: _result!.score),
      const SizedBox(height: 14),
      if (s == null)
        FilledButton.icon(
          onPressed: _start,
          icon: Icon(_result == null ? Icons.play_arrow_rounded : Icons.replay_rounded),
          label: Text(_result == null ? 'Start (1 bar count-in)' : 'Try again'),
        ),
      const SizedBox(height: 10),
      if (s == null)
        Center(
          child: HearButton(
            label: 'Hear the pattern',
            onPressed: () => _services.player.playProgression(
              key: 'strum:${step.pattern}:${step.chordIds.join()}',
              barChords: [for (var b = 0; b < step.chordIds.length.clamp(2, 4); b++) step.chordForBar(b)],
              pattern: step.pattern,
              beatsPerBar: step.beatsPerBar,
              bpm: step.bpm,
              library: _services.library,
            ),
          ),
        ),
      const SizedBox(height: 14),
      const ListeningBadge(message: 'Listening for your strums'),
      const SizedBox(height: 6),
      const Text('Tip: a little distance between phone speaker and guitar helps the app tell clicks from strums.',
          style: TextStyle(color: kMuted, fontSize: 12)),
    ]);
  }
}

class _PatternRow extends StatelessWidget {
  const _PatternRow({required this.pattern, required this.active});

  final StrumPattern pattern;
  final int active;

  @override
  Widget build(BuildContext context) {
    final slots = pattern.source.split('');
    return Row(children: [
      for (var i = 0; i < slots.length; i++)
        Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: i == active ? kAccent : kSurfaceHigh,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(children: [
              Icon(
                switch (slots[i]) { 'D' => Icons.arrow_downward_rounded, 'U' => Icons.arrow_upward_rounded, _ => Icons.circle },
                size: slots[i] == '-' ? 6 : 26,
                color: i == active ? kOnAccent : (slots[i] == '-' ? kMuted : null),
              ),
              const SizedBox(height: 4),
              Text(i.isEven ? '${i ~/ 2 + 1}' : '&',
                  style: TextStyle(
                      fontSize: 12, color: i == active ? kOnAccent : kMuted, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
    ]);
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.timing, required this.chords, required this.score});

  final double timing, chords, score;

  @override
  Widget build(BuildContext context) {
    final stars = starsFor(score);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < 3; i++)
              Icon(i < stars ? Icons.star_rounded : Icons.star_outline_rounded, color: kAccent, size: 34),
          ]),
          const SizedBox(height: 8),
          Text('Timing ${(timing * 100).round()}% · Chords ${(chords * 100).round()}%',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            score >= 0.7 ? 'Solid rhythm! Continue, or go again to polish it.' : 'Keep going: try again at a relaxed pace.',
            style: const TextStyle(color: kMuted),
          ),
        ]),
      ),
    );
  }
}
