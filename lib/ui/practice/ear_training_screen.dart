import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../audio/analysis.dart';
import '../../audio/chord_matcher.dart';
import '../../music/chord.dart';
import '../../music/notes.dart';
import '../../practice/ear.dart';
import '../../practice/trackers.dart';
import '../../progress/practice_log.dart';
import '../theme.dart';
import '../widgets/listening.dart';
import '../widgets/listening_badge.dart';
import '../widgets/tab_staff.dart';

enum EarMode {
  quality('Major or minor?', 'ear:quality'),
  echo('Play it back', 'ear:echo');

  const EarMode(this.label, this.game);

  final String label;

  /// Where its best score is kept.
  final String game;
}

/// Ear training: tell major chords from minor by their sound, and play back short phrases after
/// hearing them, the way musicians learn songs by ear.
class EarTrainingScreen extends StatefulWidget {
  const EarTrainingScreen({super.key, this.random});

  /// For tests: the questions in a known order.
  final math.Random? random;

  @override
  State<EarTrainingScreen> createState() => _EarTrainingScreenState();
}

class _EarTrainingScreenState extends State<EarTrainingScreen> {
  late final AppServices _services = context.read<AppServices>();
  late final math.Random _random = widget.random ?? math.Random();
  EarMode _mode = EarMode.quality;
  bool _running = false, _over = false, _newBest = false;
  int _score = 0;

  // Major or minor: ten chords.
  static const _questions = 10;
  int _asked = 0;
  Chord? _chord;
  bool? _wasRight;

  // Play it back: phrases that grow a note longer every second one played right.
  int _length = 2;
  List<FretNote> _phrase = const [];
  SequenceTracker<FretNote>? _tracker;
  bool _reveal = false;

  bool get _phraseDone => _tracker?.done ?? false;

  void _start() {
    setState(() {
      _running = true;
      _over = false;
      _score = 0;
      _asked = 0;
      _length = 2;
    });
    _mode == EarMode.quality ? _nextChord() : _nextPhrase();
  }

  void _finish() {
    final best = context.read<PracticeLog>().recordBest(_mode.game, _score);
    setState(() {
      _running = false;
      _over = true;
      _newBest = best;
    });
  }

  void _nextChord() {
    if (_asked == _questions) return _finish();
    final pool = _random.nextBool() ? majorChords : minorChords;
    final chord = _services.library.byId(pool[_random.nextInt(pool.length)]);
    setState(() {
      _chord = chord;
      _wasRight = null;
      _asked++;
    });
    _services.player.playChord(chord);
  }

  void _answerQuality(bool major) {
    final chord = _chord;
    if (chord == null || _wasRight != null) return;
    final right = majorChords.contains(chord.id) == major;
    setState(() {
      _wasRight = right;
      if (right) _score++;
    });
  }

  void _nextPhrase() {
    final phrase = echoPhrase(_length, _random);
    setState(() {
      _phrase = phrase;
      _reveal = false;
      _tracker = SequenceTracker<FretNote>(targets: phrase, matcher: (f, n) => NoteMatcher.matches(f, n.midi), requiredFrames: 1);
    });
    _playPhrase();
  }

  void _playPhrase() => _services.player.playTab('ear:${Object.hashAll(_phrase)}', phraseTab(_phrase), bpm: 80);

  void _hear(AnalysisFrame f) {
    final tracker = _tracker;
    if (tracker == null || tracker.done || !tracker.process(f)) return;
    setState(() {
      if (!tracker.done) return;
      _score++;
      // Longer phrases once two in a row come easily.
      if (_score.isEven) _length = math.min(6, _length + 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final best = context.select<PracticeLog, int?>((p) => p.best(_mode.game));
    return Scaffold(
      appBar: AppBar(title: const Text('Ear training')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          if (!_running) ...[
            SegmentedButton<EarMode>(
              segments: [for (final m in EarMode.values) ButtonSegment(value: m, label: Text(m.label))],
              selected: {_mode},
              onSelectionChanged: (v) => setState(() {
                _mode = v.first;
                _over = false;
              }),
            ),
            const SizedBox(height: 12),
            Text(
              _mode == EarMode.quality
                  ? 'Guitaro strums a chord: is it major (bright, happy) or minor (darker, sad)? Ten chords.'
                  : 'Guitaro plays a few notes on the top three strings, near the nut. Play them back. '
                      'The phrases grow as you get them.',
              style: const TextStyle(fontSize: 16, height: 1.4),
            ),
          ],
          if (_running && _mode == EarMode.quality) ..._qualityView(),
          if (_running && _mode == EarMode.echo) ..._echoView(),
          if (_over) ...[
            const SizedBox(height: 16),
            Icon(_newBest ? Icons.emoji_events_rounded : Icons.check_circle_rounded, size: 64, color: _newBest ? kAccent : kSuccess),
            Text(_mode == EarMode.quality ? '$_score of $_questions right' : '$_score phrase${_score == 1 ? '' : 's'} played back',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
            Text(_newBest ? 'A new best!' : 'Your best is ${best ?? 0}.', textAlign: TextAlign.center),
          ],
          if (!_running) ...[
            const SizedBox(height: 16),
            if (!_over && best != null) Text('Your best: $best', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            FilledButton.icon(onPressed: _start, icon: const Icon(Icons.hearing_rounded), label: Text(_over ? 'Again' : 'Start')),
          ],
        ]),
      ),
    );
  }

  List<Widget> _qualityView() {
    final answered = _wasRight != null;
    return [
      Text('Chord $_asked of $_questions · $_score right', textAlign: TextAlign.center, style: const TextStyle(color: kMuted)),
      const SizedBox(height: 16),
      Center(
        child: IconButton.filledTonal(
          iconSize: 56,
          tooltip: 'Hear it again',
          onPressed: () => _services.player.playChord(_chord!),
          icon: const Icon(Icons.volume_up_rounded),
        ),
      ),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: FilledButton(onPressed: answered ? null : () => _answerQuality(true), child: const Text('Major'))),
        const SizedBox(width: 12),
        Expanded(child: FilledButton(onPressed: answered ? null : () => _answerQuality(false), child: const Text('Minor'))),
      ]),
      const SizedBox(height: 14),
      if (answered) ...[
        Text(
          '${_wasRight! ? 'Yes!' : 'Not quite.'} That was ${_chord!.name}.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _wasRight! ? kSuccess : kMiss),
        ),
        const SizedBox(height: 10),
        FilledButton.tonal(onPressed: _nextChord, child: Text(_asked == _questions ? 'See my score' : 'Next chord')),
      ],
    ];
  }

  List<Widget> _echoView() {
    final played = _tracker?.index ?? 0;
    return [
      Text('$_score played back · ${_phrase.length} notes', textAlign: TextAlign.center, style: const TextStyle(color: kMuted)),
      const SizedBox(height: 16),
      // A circle per note: a question mark until it's played right.
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < _phrase.length; i++)
          Container(
            margin: const EdgeInsets.all(4),
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: i < played ? kSuccess : kSurfaceHigh),
            child: Text(i < played ? noteName(_phrase[i].midi) : '?',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: i < played ? kOnAccent : kMuted)),
          ),
      ]),
      const SizedBox(height: 12),
      if (_reveal)
        TabStaff(columns: [for (final n in _phrase) TabColumn.note(n)], current: played, markDone: true, columnWidth: 40),
      const SizedBox(height: 8),
      Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
        OutlinedButton.icon(onPressed: _playPhrase, icon: const Icon(Icons.replay_rounded), label: const Text('Hear it again')),
        if (!_reveal && !_phraseDone) TextButton(onPressed: () => setState(() => _reveal = true), child: const Text('Show me')),
      ]),
      if (_phraseDone) ...[
        const SizedBox(height: 8),
        const Text('Yes! Played back.', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: kSuccess)),
        const SizedBox(height: 8),
        FilledButton.tonal(onPressed: _nextPhrase, child: const Text('Next phrase')),
      ] else ...[
        const SizedBox(height: 8),
        FrameListener(onFrame: _hear),
        const ListeningBadge(),
      ],
      const SizedBox(height: 8),
      Center(child: TextButton(onPressed: _finish, child: const Text('Finish'))),
    ];
  }
}
