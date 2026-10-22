import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../progress/progress_store.dart';
import '../theme.dart';
import '../widgets/brand_mark.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

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
          SwitchListTile(
            title: const Text('Left-handed diagrams'),
            subtitle: const Text('Mirror chord charts and fretboards'),
            value: progress.leftHanded,
            onChanged: (v) => progress.leftHanded = v,
          ),
          SwitchListTile(
            title: const Text('Unlock all lessons'),
            subtitle: const Text('Jump ahead if you already play'),
            value: progress.unlockAll,
            onChanged: (v) => progress.unlockAll = v,
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
