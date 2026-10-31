import 'package:flutter/material.dart';

import '../../progress/learning_goal.dart';
import '../theme.dart';

/// What the learner sets out to do: where they start, what they want to play, and how long a
/// day; when first setting it, a daily reminder too.
class GoalForm extends StatefulWidget {
  const GoalForm({super.key, required this.initial, required this.doneLabel, required this.onDone, this.askReminder = false});

  final LearningGoal initial;
  final String doneLabel;

  /// With the reminder time chosen, if any.
  final void Function(LearningGoal goal, TimeOfDay? reminder) onDone;
  final bool askReminder;

  @override
  State<GoalForm> createState() => _GoalFormState();
}

class _GoalFormState extends State<GoalForm> {
  late Experience _experience = widget.initial.experience;
  late final Set<Aim> _aims = {...widget.initial.aims};
  late int _minutes = widget.initial.minutes;
  bool _remind = true;
  TimeOfDay _at = const TimeOfDay(hour: 18, minute: 0);

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _at, helpText: 'Remind me to practise at');
    if (picked != null) setState(() => _at = picked);
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      );

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _heading('Where are you starting?'),
        for (final e in Experience.values)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: e == _experience ? kAccent : Colors.transparent, width: 2),
            ),
            child: ListTile(
              leading: Icon(e == _experience ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: kAccent),
              title: Text(e.label, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(e.detail),
              onTap: () => setState(() => _experience = e),
            ),
          ),
        _heading('What do you want to play?'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final a in Aim.values)
            FilterChip(
              label: Text(a.label),
              selected: _aims.contains(a),
              onSelected: (on) => setState(() => on ? _aims.add(a) : _aims.remove(a)),
            ),
        ]),
        _heading('How long can you practise a day?'),
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: [for (final m in LearningGoal.dailyMinutes) ButtonSegment(value: m, label: Text('$m min'))],
          selected: {_minutes},
          onSelectionChanged: (v) => setState(() => _minutes = v.first),
        ),
        const SizedBox(height: 6),
        Text(
          _minutes <= 5 ? 'Little and often works: five minutes every day beats an hour once a week.' : "Today's practice will fit this.",
          style: const TextStyle(color: kMuted, fontSize: 13),
        ),
        if (widget.askReminder) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Remind me every day', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(_remind ? 'At ${_at.format(context)}: tap to change' : 'No reminder'),
            value: _remind,
            onChanged: (v) => setState(() => _remind = v),
          ),
          if (_remind) Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: _pickTime, child: const Text('Change the time'))),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _aims.isEmpty
              ? null
              : () => widget.onDone(
                    LearningGoal(experience: _experience, aims: {..._aims}, minutes: _minutes),
                    widget.askReminder && _remind ? _at : null,
                  ),
          child: Text(widget.doneLabel),
        ),
      ]);
}
