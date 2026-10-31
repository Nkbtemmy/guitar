import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../practice/reminders.dart';
import '../../progress/learning_goal.dart';
import '../../progress/progress_store.dart';
import '../theme.dart';
import '../widgets/brand_mark.dart';
import 'goal_form.dart';

/// The first time the app opens: a welcome, then the learner's goal (where they start, what
/// they want to play, how long a day, and a reminder), then on to [next].
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.next});

  final Widget next;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _welcomed = false;

  Future<void> _finish(LearningGoal goal, TimeOfDay? reminder) async {
    final progress = context.read<ProgressStore>();
    final reminders = context.read<Reminders>();
    final navigator = Navigator.of(context);
    progress.goal = goal;
    // The reminder is a nice-to-have: if notifications aren't allowed, carry on without it.
    if (reminder != null && await reminders.askPermission()) progress.reminder = reminder.hour * 60 + reminder.minute;
    navigator.pushReplacement(MaterialPageRoute<void>(builder: (_) => widget.next));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: _welcomed
              ? ListView(padding: const EdgeInsets.all(20), children: [
                  const Text('Your goal', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
                  const Text('So Guitaro can plan your practice. You can change it any time in Me.', style: TextStyle(color: kMuted)),
                  GoalForm(initial: const LearningGoal(), doneLabel: "Let's go", askReminder: true, onDone: _finish),
                ])
              : _welcome(),
        ),
      );

  Widget _welcome() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Spacer(),
          const Center(child: BrandMark(size: 96)),
          const SizedBox(height: 24),
          const Text('Welcome to Guitaro', textAlign: TextAlign.center, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          const Text(
            'Learn guitar from your very first note to whole songs. Guitaro listens as you play, and tells you how it went.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: kMuted, height: 1.4),
          ),
          const Spacer(),
          FilledButton(onPressed: () => setState(() => _welcomed = true), child: const Text('Get started')),
        ]),
      );
}
