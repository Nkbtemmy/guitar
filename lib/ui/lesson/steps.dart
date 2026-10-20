import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../audio/analysis.dart';
import '../../audio/chord_matcher.dart';
import '../../curriculum/models.dart';
import '../../music/chord.dart';
import '../../music/chord_library.dart';
import '../../music/notes.dart';
import '../../practice/trackers.dart';
import '../theme.dart';
import '../tuner/tuner_panel.dart';
import '../widgets/chord_diagram.dart';
import '../widgets/fretboard.dart';
import '../widgets/listening.dart';
import '../widgets/listening_badge.dart';

typedef StepDone = void Function(double score);

class StepTitle extends StatelessWidget {
  const StepTitle(this.title, {super.key, this.body});

  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.15)),
        if (body != null) ...[
          const SizedBox(height: 10),
          Text(body!, style: const TextStyle(fontSize: 16.5, height: 1.45, color: Color(0xFFDCD3CB))),
        ],
      ]);
}

class HearButton extends StatelessWidget {
  const HearButton({super.key, required this.onPressed, this.label = 'Hear it'});

  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.volume_up_rounded),
        label: Text(label),
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
      );
}

class InfoStepView extends StatefulWidget {
  const InfoStepView({super.key, required this.step, required this.onDone});

  final InfoStep step;
  final StepDone onDone;

  @override
  State<InfoStepView> createState() => _InfoStepViewState();
}

class _InfoStepViewState extends State<InfoStepView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onDone(1));
  }

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final chord = widget.step.chordId == null ? null : services.library.byId(widget.step.chordId!);
    return ListView(padding: const EdgeInsets.all(20), children: [
      StepTitle(widget.step.title!, body: widget.step.body),
      if (chord != null) ...[
        const SizedBox(height: 24),
        Center(child: ChordDiagram(chord: chord, width: 170, showName: true)),
        const SizedBox(height: 12),
        for (final line in chord.placement)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(line, textAlign: TextAlign.center, style: const TextStyle(color: kMuted)),
          ),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          HearButton(onPressed: () => services.player.playChord(chord)),
          const SizedBox(width: 12),
          HearButton(label: 'String by string', onPressed: () => services.player.playChord(chord, slow: true)),
        ]),
      ],
    ]);
  }
}

class QuizStepView extends StatefulWidget {
  const QuizStepView({super.key, required this.step, required this.onDone});

  final QuizStep step;
  final StepDone onDone;

  @override
  State<QuizStepView> createState() => _QuizStepViewState();
}

class _QuizStepViewState extends State<QuizStepView> {
  final _wrong = <int>{};
  bool _right = false;

  void _pick(int i) {
    if (_right) return;
    setState(() {
      if (i == widget.step.answer) {
        _right = true;
        widget.onDone(_wrong.isEmpty ? 1 : 0.5);
      } else {
        _wrong.add(i);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.step;
    return ListView(padding: const EdgeInsets.all(20), children: [
      StepTitle(s.question),
      const SizedBox(height: 20),
      for (var i = 0; i < s.options.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _Option(
            text: s.options[i],
            state: _right && i == s.answer ? true : (_wrong.contains(i) ? false : null),
            onTap: () => _pick(i),
          ),
        ),
      if (_wrong.isNotEmpty && !_right)
        const Text('Not quite. Try another answer.', style: TextStyle(color: kMiss, fontWeight: FontWeight.w600)),
      if (_right && s.explain != null)
        Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: kSuccess.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
          child: Text(s.explain!, style: const TextStyle(fontSize: 15, height: 1.4)),
        ),
    ]);
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.text, required this.state, required this.onTap});

  final String text;
  final bool? state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) { true => kSuccess, false => kMiss, null => kSurfaceHigh };
    return Material(
      color: state == null ? kSurface : color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: color, width: 1.5)),
          child: Row(children: [
            Expanded(child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            if (state != null) Icon(state! ? Icons.check_circle_rounded : Icons.cancel_rounded, color: color),
          ]),
        ),
      ),
    );
  }
}

class TuneStepView extends StatelessWidget {
  const TuneStepView({super.key, required this.step, required this.onDone});

  final TuneStep step;
  final StepDone onDone;

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(20), children: [
        StepTitle(step.title ?? 'Tune up', body: step.body),
        const SizedBox(height: 20),
        TunerPanel(onAllTuned: () => onDone(1)),
      ]);
}

class NotesStepView extends StatefulWidget {
  const NotesStepView({super.key, required this.step, required this.onDone});

  final NotesStep step;
  final StepDone onDone;

  @override
  State<NotesStepView> createState() => _NotesStepViewState();
}

class _NotesStepViewState extends State<NotesStepView> with Listening {
  late final _tracker = SequenceTracker<FretNote>(
    targets: widget.step.notes,
    matcher: (f, n) => NoteMatcher.matches(f, n.midi),
    requiredFrames: 1,
  );
  String? _heard;
  int _flash = 0;

  @override
  void onFrame(AnalysisFrame f) {
    final p = f.pitch;
    final heard = p != null && p.clarity >= 0.85 ? 'Heard: ${noteNameWithOctave(p.midi.round())}' : null;
    final advanced = _tracker.process(f);
    if (advanced || heard != _heard) {
      setState(() {
        _heard = heard;
        if (advanced) _flash++;
      });
      if (advanced && _tracker.done) widget.onDone(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final step = widget.step;
    final current = _tracker.current;
    final chord = step.chordId == null ? null : services.library.byId(step.chordId!);
    return ListView(padding: const EdgeInsets.all(20), children: [
      StepTitle(step.title!, body: step.body),
      const SizedBox(height: 18),
      if (chord != null) ...[
        Center(child: ChordDiagram(chord: chord, width: 110, showName: true)),
        const SizedBox(height: 12),
      ],
      if (current != null) ...[
        Fretboard(target: current, upcoming: step.notes.skip(_tracker.index + 1).toList()),
        const SizedBox(height: 8),
        Center(
          child: Text('${current.label} · ${noteName(current.midi)}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ),
      ] else
        const _DoneBanner(text: 'All notes played!'),
      const SizedBox(height: 14),
      _SequenceChips(
        labels: [for (final n in step.notes) '${stringLetters[n.string]}${n.fret}'],
        index: _tracker.index,
        flash: _flash,
      ),
      const SizedBox(height: 14),
      if (current != null)
        Center(child: HearButton(label: 'Hear this note', onPressed: () => services.player.playNote(current.midi))),
      const SizedBox(height: 14),
      ListeningBadge(message: _heard),
    ]);
  }
}

/// Drills one chord (repeat) or a sequence of changes; each needs a fresh strum.
class ChordSequenceView extends StatefulWidget {
  const ChordSequenceView({super.key, required this.title, required this.body, required this.chordIds, required this.onDone});

  final String title;
  final String body;
  final List<String> chordIds;
  final StepDone onDone;

  static ChordSequenceView forStep(LessonStep step, StepDone onDone, ChordLibrary library) => switch (step) {
        ChordStep(:final chordId, :final repeat, :final body) => ChordSequenceView(
            title: 'Play ${library.byId(chordId).symbol}',
            body: body ?? 'Strum ${library.byId(chordId).name} $repeat times. Let each strum ring, then strum again.',
            chordIds: List.filled(repeat, chordId),
            onDone: onDone,
          ),
        ChangeStep(:final chordIds, :final body, :final sequence) => ChordSequenceView(
            title: 'Change: ${chordIds.map((c) => library.byId(c).symbol).join(' → ')}',
            body: body ?? 'Strum each chord once, then switch. Move all your fingers together.',
            chordIds: sequence,
            onDone: onDone,
          ),
        _ => throw ArgumentError(step),
      };

  @override
  State<ChordSequenceView> createState() => _ChordSequenceViewState();
}

class _ChordSequenceViewState extends State<ChordSequenceView> with Listening {
  late final AppServices _services = context.read<AppServices>();
  late final List<Chord> _chords = [for (final id in widget.chordIds) _services.library.byId(id)];
  ChordVerdict? _verdict;
  late final _tracker = SequenceTracker<Chord>(
    targets: _chords,
    matcher: (f, c) => _verdict?.matches ?? false,
  );
  double? _lastOnset;
  String? _hint;
  int _flash = 0;

  @override
  void onFrame(AnalysisFrame f) {
    final target = _tracker.current;
    if (target == null) return;
    _verdict = f.hasSound ? _services.matcher.verify(f.peaks, target) : null;
    if (f.onsets.isNotEmpty) _lastOnset = f.onsets.last;
    final advanced = _tracker.process(f);
    String? hint = _hint;
    if (advanced) {
      hint = null;
      _lastOnset = null;
    } else if (_lastOnset != null && f.time - _lastOnset! > 0.6 && _verdict != null && !_verdict!.matches) {
      final best = _verdict!.best;
      hint = best.pitchClasses.length == target.pitchClasses.length && best.pitchClasses.containsAll(target.pitchClasses)
          ? 'Almost! Let every string ring clearly.'
          : 'That sounds more like ${best.symbol}. Check each finger and string.';
      _lastOnset = null;
    }
    setState(() {
      _hint = hint;
      if (advanced) _flash++;
    });
    if (advanced && _tracker.done) widget.onDone(1);
  }

  @override
  Widget build(BuildContext context) {
    final current = _tracker.current;
    final next = _tracker.index + 1 < _chords.length ? _chords[_tracker.index + 1] : null;
    final score = _verdict?.score ?? 0;
    return ListView(padding: const EdgeInsets.all(20), children: [
      StepTitle(widget.title, body: widget.body),
      const SizedBox(height: 20),
      if (current != null)
        Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: ChordDiagram(key: ValueKey(_tracker.index), chord: current, width: 170, showName: true),
          ),
          if (next != null && next.id != current.id) ...[
            const SizedBox(width: 18),
            Opacity(
              opacity: 0.55,
              child: Column(children: [
                const Text('Next', style: TextStyle(color: kMuted, fontSize: 12)),
                ChordDiagram(chord: next, width: 80, showName: true),
              ]),
            ),
          ],
        ])
      else
        const _DoneBanner(text: 'Great strumming!'),
      const SizedBox(height: 16),
      _SequenceChips(labels: [for (final c in _chords) c.symbol], index: _tracker.index, flash: _flash),
      const SizedBox(height: 14),
      if (current != null) ...[
        Row(children: [
          const Text('Match ', style: TextStyle(color: kMuted)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: score,
                minHeight: 10,
                color: (_verdict?.matches ?? false) ? kSuccess : kAccent,
                backgroundColor: kSurfaceHigh,
              ),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        SizedBox(height: 22, child: Text(_hint ?? '', style: const TextStyle(color: kAccent, fontWeight: FontWeight.w600))),
        Center(child: HearButton(onPressed: () => _services.player.playChord(current))),
      ],
      const SizedBox(height: 14),
      const ListeningBadge(),
    ]);
  }
}

class _SequenceChips extends StatelessWidget {
  const _SequenceChips({required this.labels, required this.index, required this.flash});

  final List<String> labels;
  final int index;
  final int flash;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < labels.length; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: i < index ? kSuccess.withValues(alpha: 0.2) : (i == index ? kAccent.withValues(alpha: 0.2) : kSurfaceHigh),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: i == index ? kAccent : Colors.transparent, width: 1.5),
            ),
            child: Text(
              labels[i],
              style: TextStyle(fontWeight: FontWeight.w700, color: i < index ? kSuccess : null),
            ),
          ),
      ],
    );
  }
}

class _DoneBanner extends StatelessWidget {
  const _DoneBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 28),
        alignment: Alignment.center,
        child: Column(children: [
          const Icon(Icons.celebration_rounded, color: kSuccess, size: 56),
          const SizedBox(height: 8),
          Text(text, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: kSuccess)),
        ]),
      );
}
