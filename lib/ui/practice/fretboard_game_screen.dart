import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../audio/analysis.dart';
import '../../audio/chord_matcher.dart';
import '../../music/notes.dart';
import '../../progress/practice_log.dart';
import '../theme.dart';
import '../widgets/fretboard.dart';
import '../widgets/listening.dart';
import '../widgets/listening_badge.dart';

/// The game's two ways to play: name the note at a spot, or find a named note and play it.
enum FretboardMode {
  name('Name it', 'fretboard:name'),
  play('Play it', 'fretboard:play');

  const FretboardMode(this.label, this.game);

  final String label;

  /// Where its best score is kept.
  final String game;
}

/// Learning the notes on the neck, against the clock. "Name it" shows a spot to name; "Play it"
/// names a note and a string, and listens for it. Natural notes in the first frets to start
/// with, sharps and the whole neck when ready.
class FretboardGameScreen extends StatefulWidget {
  const FretboardGameScreen({super.key, this.length = const Duration(minutes: 1), this.random});

  final Duration length;

  /// For tests: the questions in a known order.
  final math.Random? random;

  @override
  State<FretboardGameScreen> createState() => _FretboardGameScreenState();
}

class _FretboardGameScreenState extends State<FretboardGameScreen> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late final math.Random _random = widget.random ?? math.Random();
  FretboardMode _mode = FretboardMode.name;
  bool _sharps = false, _wholeNeck = false;
  bool _running = false, _over = false, _newBest = false;
  Duration _elapsed = Duration.zero;
  // Replaced by a real question on Start; never shown before.
  FretNote _question = const FretNote(6, 0);
  int _score = 0, _tries = 0;

  /// The last answer: right or wrong, and the note it should have been.
  (bool, String)? _feedback;

  int get _maxFret => _wholeNeck ? 12 : 5;

  FretNote _ask() {
    while (true) {
      final note = FretNote(1 + _random.nextInt(6), _random.nextInt(_maxFret + 1));
      if (!_sharps && noteName(note.midi).contains('#')) continue;
      if (note == _question) continue;
      return note;
    }
  }

  void _start() {
    setState(() {
      _running = true;
      _over = false;
      _score = 0;
      _tries = 0;
      _feedback = null;
      _elapsed = Duration.zero;
      _question = _ask();
    });
    _ticker
      ..stop()
      ..start();
  }

  void _tick(Duration elapsed) {
    if (elapsed >= widget.length) {
      _ticker.stop();
      final best = context.read<PracticeLog>().recordBest(_mode.game, _score);
      setState(() {
        _running = false;
        _over = true;
        _newBest = best;
      });
      return;
    }
    if (elapsed.inSeconds != _elapsed.inSeconds) setState(() => _elapsed = elapsed);
  }

  void _answer(String name) {
    if (!_running) return;
    final right = noteName(_question.midi) == name;
    setState(() {
      _tries++;
      if (right) _score++;
      _feedback = (right, noteName(_question.midi));
      _question = _ask();
    });
  }

  void _hear(AnalysisFrame f) {
    if (_running && NoteMatcher.matches(f, _question.midi)) _answer(noteName(_question.midi));
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final best = context.select<PracticeLog, int?>((p) => p.best(_mode.game));
    final left = widget.length - _elapsed;
    return Scaffold(
      appBar: AppBar(title: const Text('Fretboard notes')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          if (!_running) ...[
            SegmentedButton<FretboardMode>(
              segments: [for (final m in FretboardMode.values) ButtonSegment(value: m, label: Text(m.label))],
              selected: {_mode},
              onSelectionChanged: (v) => setState(() {
                _mode = v.first;
                _over = false;
              }),
            ),
            const SizedBox(height: 8),
            Text(
              _mode == FretboardMode.name
                  ? 'A dot shows a spot on the neck: tap the note it is.'
                  : 'Find the note on the string named, and play it. Guitaro listens.',
              style: const TextStyle(color: kMuted),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Sharps too'),
              value: _sharps,
              onChanged: (v) => setState(() => _sharps = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Up to fret 12'),
              subtitle: const Text('Off: the first five frets'),
              value: _wholeNeck,
              onChanged: (v) => setState(() => _wholeNeck = v),
            ),
          ],
          if (_running) ...[
            Row(children: [
              Text('Score $_score', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              const Spacer(),
              Text('${left.inSeconds.clamp(0, widget.length.inSeconds)} s', style: const TextStyle(fontSize: 18, color: kMuted)),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(value: _elapsed.inMilliseconds / widget.length.inMilliseconds, minHeight: 8),
            ),
            const SizedBox(height: 16),
            if (_mode == FretboardMode.name) ...[
              Fretboard(target: _question, showName: false),
              const SizedBox(height: 14),
              _NoteButtons(sharps: _sharps, onTap: _answer),
            ] else ...[
              Text('Play ${noteName(_question.midi)}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w900)),
              Text('on the ${stringLetters[_question.string]!.toUpperCase()} string (string ${_question.string})',
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
              const SizedBox(height: 12),
              FrameListener(onFrame: _hear),
              const ListeningBadge(),
              Center(child: TextButton(onPressed: () => _answer(''), child: const Text('Skip'))),
            ],
            const SizedBox(height: 10),
            if (_feedback case (final right, final was))
              Text(right ? 'Yes!' : 'That was $was.',
                  textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w800, color: right ? kSuccess : kMiss)),
          ],
          if (_over) ...[
            const SizedBox(height: 10),
            Icon(_newBest ? Icons.emoji_events_rounded : Icons.check_circle_rounded, size: 64, color: _newBest ? kAccent : kSuccess),
            Text('$_score right of $_tries', textAlign: TextAlign.center, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
            Text(_newBest ? 'A new best!' : 'Your best is ${best ?? 0}.', textAlign: TextAlign.center),
          ],
          if (!_running) ...[
            const SizedBox(height: 16),
            if (!_over && best != null) Text('Your best: $best', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(_over ? 'Again' : 'Start: ${widget.length.inSeconds} seconds'),
            ),
          ],
        ]),
      ),
    );
  }
}

class _NoteButtons extends StatelessWidget {
  const _NoteButtons({required this.sharps, required this.onTap});

  final bool sharps;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    Widget row(List<String> names) => Row(children: [
          for (final n in names)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: FilledButton.tonal(
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: () => onTap(n),
                  child: FittedBox(child: Text(n, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                ),
              ),
            ),
        ]);
    return Column(children: [
      if (sharps) row(const ['C#', 'D#', 'F#', 'G#', 'A#']),
      row(const ['C', 'D', 'E', 'F', 'G', 'A', 'B']),
    ]);
  }
}
