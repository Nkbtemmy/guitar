import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../practice/reminders.dart';
import '../../progress/learning_goal.dart';
import '../../progress/progress_store.dart';
import '../account/account_card.dart';
import '../onboarding/goal_form.dart';
import '../theme.dart';
import '../widgets/brand_mark.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  /// Turns the daily reminder on, at a time the learner picks, if notifications are allowed.
  Future<void> _setReminder(BuildContext context) async {
    final progress = context.read<ProgressStore>();
    final reminders = context.read<Reminders>();
    final messenger = ScaffoldMessenger.of(context);
    final at = progress.reminder ?? 18 * 60;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: at ~/ 60, minute: at % 60),
      helpText: 'Remind me to practise at',
    );
    if (picked == null) return;
    if (!await reminders.askPermission()) {
      messenger.showSnackBar(const SnackBar(content: Text('Notifications are off for Guitaro: turn them on in the phone\'s Settings.')));
      return;
    }
    progress.reminder = picked.hour * 60 + picked.minute;
  }

  @override
  Widget build(BuildContext context) {
    final progress = context.watch<ProgressStore>();
    final total = context.read<AppServices>().curriculum.lessons.length;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 24), children: [
      const Text('Me', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
      const SizedBox(height: 16),
      Row(children: [
        _Stat(icon: Icons.local_fire_department_rounded, value: '${progress.streak()}', label: 'Day streak'),
        const SizedBox(width: 10),
        _Stat(icon: Icons.bolt_rounded, value: '${progress.xp}', label: 'XP'),
        const SizedBox(width: 10),
        _Stat(icon: Icons.star_rounded, value: '${progress.totalStars}', label: 'Stars'),
      ]),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Course progress: ${progress.lessonsCompleted} of $total lessons',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress.lessonsCompleted / total,
                minHeight: 10,
                color: kAccent,
                backgroundColor: kSurfaceHigh,
              ),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: ListTile(
          leading: const Icon(Icons.flag_rounded, color: kAccent),
          title: const Text('My goal', style: TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(switch (progress.goal) {
            null => 'Not set: tap to choose',
            final g => '${g.aims.map((a) => a.label).join(', ')} · ${g.minutes} min a day',
          }),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (c) => Scaffold(
              appBar: AppBar(title: const Text('My goal')),
              body: SafeArea(
                child: ListView(padding: const EdgeInsets.all(20), children: [
                  GoalForm(
                    initial: progress.goal ?? const LearningGoal(),
                    doneLabel: 'Save',
                    onDone: (goal, _) {
                      progress.goal = goal;
                      Navigator.of(c).pop();
                    },
                  ),
                ]),
              ),
            ),
          )),
        ),
      ),
      const SizedBox(height: 12),
      const AccountCard(),
      const SizedBox(height: 24),
      const Text('Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Card(
        child: Column(children: [
          ListTile(
            title: const Text('Microphone sensitivity'),
            subtitle: Slider(value: progress.sensitivity, onChanged: (v) => progress.sensitivity = v),
            trailing: Text(progress.sensitivity < 0.34 ? 'Low' : (progress.sensitivity < 0.67 ? 'Medium' : 'High')),
          ),
          ListTile(
            title: const Text('Chord display'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<ChordDisplay>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ChordDisplay.both, label: Text('Both')),
                  ButtonSegment(value: ChordDisplay.tab, label: Text('Tab')),
                  ButtonSegment(value: ChordDisplay.diagram, label: Text('Diagram')),
                ],
                selected: {progress.chordDisplay},
                onSelectionChanged: (v) => progress.chordDisplay = v.first,
              ),
            ),
          ),
          ListTile(
            title: const Text('Chord charts'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<ChordOrientation>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ChordOrientation.upright, label: Text('Chord book')),
                  ButtonSegment(value: ChordOrientation.sideways, label: Text('Sideways')),
                ],
                selected: {progress.chordOrientation},
                onSelectionChanged: (v) => progress.chordOrientation = v.first,
              ),
            ),
          ),
          ListTile(
            title: const Text('String order'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('In tabs, chord charts and fretboards'),
                const SizedBox(height: 8),
                SegmentedButton<StringOrder>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: StringOrder.lowOnTop, label: Text('Low E on top')),
                    ButtonSegment(value: StringOrder.highOnTop, label: Text('High e on top')),
                  ],
                  selected: {progress.stringOrder},
                  onSelectionChanged: (v) => progress.stringOrder = v.first,
                ),
              ]),
            ),
          ),
          SwitchListTile(
            title: const Text('Left-handed diagrams'),
            subtitle: const Text('Mirror chord charts and fretboards'),
            value: progress.leftHanded,
            onChanged: (v) => progress.leftHanded = v,
          ),
          SwitchListTile(
            title: const Text('Keep the screen on'),
            subtitle: const Text("So it doesn't go dark while your hands are on the guitar"),
            value: progress.keepScreenOn,
            onChanged: (v) => progress.keepScreenOn = v,
          ),
          ListTile(
            title: const Text('Practice reminder'),
            subtitle: Text(progress.reminder == null
                ? 'Off'
                : 'Every day at ${TimeOfDay(hour: progress.reminder! ~/ 60, minute: progress.reminder! % 60).format(context)}'),
            onTap: () => _setReminder(context),
            trailing: Switch(
              value: progress.reminder != null,
              onChanged: (on) => on ? _setReminder(context) : progress.reminder = null,
            ),
          ),
          SwitchListTile(
            title: const Text('Keep playing when I miss'),
            subtitle: const Text("Playing along, carry on through missed notes instead of going back"),
            value: progress.keepPlaying,
            onChanged: (v) => progress.keepPlaying = v,
          ),
          SwitchListTile(
            title: const Text('Opening sound'),
            subtitle: const Text('Strum the open strings when the app starts'),
            value: progress.openingSound,
            onChanged: (v) => progress.openingSound = v,
          ),
          SwitchListTile(
            title: const Text('Unlock all lessons'),
            subtitle: const Text('Jump ahead if you already play'),
            value: progress.unlockAll,
            onChanged: (v) => progress.unlockAll = v,
          ),
          SwitchListTile(
            title: const Text('Share anonymous usage stats'),
            subtitle: const Text('Helps improve Guitaro. Never includes what you play or your songs.'),
            value: progress.shareUsage,
            onChanged: (v) => progress.shareUsage = v,
          ),
          ListTile(
            title: const Text('Reset progress', style: TextStyle(color: kMiss)),
            leading: const Icon(Icons.restart_alt_rounded, color: kMiss),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Reset progress?'),
                  content: const Text('This clears stars, XP and your streak.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
                  ],
                ),
              );
              if (ok ?? false) progress.reset();
            },
          ),
        ]),
      ),
      const SizedBox(height: 16),
      const Text(
        'Tip: practise in a quiet room with the phone about half a metre from the guitar. '
        'If the app misses soft playing, raise the sensitivity; if it reacts to background noise, lower it.',
        style: TextStyle(color: kMuted, height: 1.4),
      ),
      const SizedBox(height: 32),
      const Center(child: BrandMark(size: 44)),
      const SizedBox(height: 8),
      const Center(
        child: Text('PLAY · LEARN · GROW',
            style: TextStyle(color: kAccent, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 3)),
      ),
    ]);
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.value, required this.label});

  final IconData icon;
  final String value, label;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(children: [
              Icon(icon, color: kAccent),
              const SizedBox(height: 6),
              Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              Text(label, style: const TextStyle(color: kMuted, fontSize: 12)),
            ]),
          ),
        ),
      );
}
