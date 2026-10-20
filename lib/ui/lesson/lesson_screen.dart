import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../curriculum/models.dart';
import '../../practice/trackers.dart';
import '../../progress/progress_store.dart';
import '../practice/song_view.dart';
import '../practice/strum_view.dart';
import '../theme.dart';
import 'steps.dart';

/// Runs a lesson step by step. Listening steps can be skipped (for fewer stars).
class LessonScreen extends StatefulWidget {
  const LessonScreen({super.key, required this.lesson});

  final Lesson lesson;

  @override
  State<LessonScreen> createState() => _LessonScreenState();
}

class _LessonScreenState extends State<LessonScreen> {
  int _index = 0;
  final _scores = <int, double>{};

  LessonStep get _step => widget.lesson.steps[_index];
  bool get _stepDone => _scores.containsKey(_index);

  void _onDone(int index, double score) {
    if (!mounted || index != _index) return;
    setState(() => _scores[index] = (_scores[index] ?? 0) > score ? _scores[index]! : score);
  }

  void _skip() {
    _scores[_index] = _step is TuneStep ? 1.0 : 0.4;
    _next();
  }

  void _next() {
    if (_index + 1 < widget.lesson.steps.length) {
      setState(() => _index++);
      return;
    }
    final scores = [for (var i = 0; i < widget.lesson.steps.length; i++) _scores[i] ?? 0.4];
    final avg = scores.reduce((a, b) => a + b) / scores.length;
    final stars = starsFor(avg);
    final xp = context.read<ProgressStore>().completeLesson(widget.lesson.id, stars);
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) => LessonCompleteScreen(lesson: widget.lesson, stars: stars, xp: xp),
    ));
  }

  Widget _buildStep(LessonStep step) {
    final services = context.read<AppServices>();
    final i = _index;
    void done(double s) => _onDone(i, s);
    return switch (step) {
      InfoStep() => InfoStepView(step: step, onDone: done),
      QuizStep() => QuizStepView(step: step, onDone: done),
      TuneStep() => TuneStepView(step: step, onDone: done),
      NotesStep() => NotesStepView(step: step, onDone: done),
      ChordStep() || ChangeStep() => ChordSequenceView.forStep(step, done, services.library),
      StrumStep() => StrumView(step: step, onDone: done),
      SongStep(:final songId) => SongView(song: services.curriculum.song(songId), onDone: done),
    };
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.lesson.steps;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).pop()),
        title: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: (_index + (_stepDone ? 1 : 0)) / steps.length,
            minHeight: 10,
            color: kAccent,
            backgroundColor: kSurfaceHigh,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text('${_index + 1}/${steps.length}', style: const TextStyle(color: kMuted)),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(child: KeyedSubtree(key: ValueKey(_index), child: _buildStep(_step))),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Row(children: [
              if (_step.listens && !_stepDone)
                TextButton(onPressed: _skip, child: Text(_step is TuneStep ? 'My guitar is in tune' : 'Skip')),
              const Spacer(),
              FilledButton(
                onPressed: _stepDone ? _next : null,
                child: Text(_index + 1 == steps.length ? 'Finish' : 'Continue'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class LessonCompleteScreen extends StatelessWidget {
  const LessonCompleteScreen({super.key, required this.lesson, required this.stars, required this.xp});

  final Lesson lesson;
  final int stars, xp;

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final progress = context.watch<ProgressStore>();
    final next = progress.nextLesson(services.curriculum);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const Spacer(),
            const Icon(Icons.emoji_events_rounded, size: 96, color: kAccent),
            const SizedBox(height: 12),
            const Text('Lesson complete!', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text(lesson.title, style: const TextStyle(fontSize: 18, color: kMuted)),
            const SizedBox(height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < 3; i++)
                Icon(i < stars ? Icons.star_rounded : Icons.star_outline_rounded, color: kAccent, size: 52),
            ]),
            const SizedBox(height: 12),
            Text('+$xp XP · ${progress.streak()} day streak',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const Spacer(),
            if (next != null && next.id != lesson.id)
              FilledButton(
                onPressed: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(builder: (_) => LessonScreen(lesson: next)),
                ),
                child: Text('Next: ${next.title}'),
              ),
            const SizedBox(height: 10),
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Back to lessons')),
          ]),
        ),
      ),
    );
  }
}
