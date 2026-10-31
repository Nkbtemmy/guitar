import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../progress/practice_log.dart';
import '../theme.dart';
import 'weak_spots_screen.dart';

/// The practice tools, as a row of tiles on the Learn tab.
class PracticeTools extends StatelessWidget {
  const PracticeTools({super.key});

  void _open(BuildContext context, Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final spots = context.select<PracticeLog, int>((p) => p.weakSpots().length);
    final tools = [
      _Tool(
        icon: Icons.healing_rounded,
        title: 'Practise these',
        subtitle: spots == 0 ? 'Your weak spots' : '$spots to fix',
        badge: spots > 0,
        onTap: () => _open(context, const WeakSpotsScreen()),
      ),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
        child: Text('Practice', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      ),
      SizedBox(
        height: 112,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: tools.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, i) => tools[i],
        ),
      ),
    ]);
  }
}

class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.title, required this.subtitle, required this.onTap, this.badge = false});

  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  final bool badge;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 124,
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Badge(isLabelVisible: badge, smallSize: 10, child: Icon(icon, color: kAccent, size: 28)),
                const Spacer(),
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMuted, fontSize: 12)),
              ]),
            ),
          ),
        ),
      );
}
