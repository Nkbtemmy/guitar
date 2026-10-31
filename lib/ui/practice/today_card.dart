import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../practice/plan.dart';
import '../../progress/practice_log.dart';
import '../../progress/progress_store.dart';
import '../lesson/lesson_screen.dart';
import '../songs/songs_screen.dart';
import '../theme.dart';
import '../tuner/tuner_panel.dart';
import 'chord_challenge_screen.dart';
import 'ear_training_screen.dart';
import 'fretboard_game_screen.dart';
import 'metronome_screen.dart';
import 'weak_spots_screen.dart';

/// Today's practice on the Learn tab: a quarter of an hour laid out the way a teacher would,
/// each part ticked off once it has been given a real try, and the minutes played today. It
/// shows what's next; the whole plan opens below it.
class TodayCard extends StatefulWidget {
  const TodayCard({super.key});

  @override
  State<TodayCard> createState() => _TodayCardState();
}

class _TodayCardState extends State<TodayCard> {
  bool _open = false;

  Future<void> _start(PlanItem item) async {
    final log = context.read<PracticeLog>();
    final navigator = Navigator.of(context);
    Future<void> push(String title, Widget screen) => navigator.push(MaterialPageRoute<void>(
          builder: (_) => title.isEmpty ? screen : Scaffold(appBar: AppBar(title: Text(title)), body: SafeArea(child: screen)),
        ));
    final started = DateTime.now();
    switch (item.kind) {
      case PlanKind.tune:
        await push('Tune up', ListView(padding: const EdgeInsets.all(20), children: const [TunerPanel()]));
      case PlanKind.fretboard:
        await push('', const FretboardGameScreen());
      case PlanKind.ear:
        await push('', const EarTrainingScreen());
      case PlanKind.changes:
        await push('', ChordChallengeScreen(pair: item.pair));
      case PlanKind.spot:
        await openSpot(context, item.spot!);
      case PlanKind.metronome:
        await push('', const MetronomeScreen());
      case PlanKind.lesson:
        await push('', LessonScreen(lesson: item.lesson!));
      case PlanKind.songs:
        await push('Songs', const SongsScreen());
    }
    // Done once given a real try: half its time, or a minute, whichever is less.
    if (DateTime.now().difference(started) >= Duration(seconds: math.min(60, item.minutes * 30))) log.markDone(item.id);
  }

  @override
  Widget build(BuildContext context) {
    final curriculum = context.read<AppServices>().curriculum;
    final progress = context.watch<ProgressStore>();
    final log = context.watch<PracticeLog>();
    final now = DateTime.now();
    final plan = dailyPlan(day: now, nextLesson: progress.nextLesson(curriculum), pair: log.lastChangePair, spot: log.weakSpots().firstOrNull);
    final done = plan.where((i) => log.isDone(i.id)).length;
    final minutes = log.practicedOn(now).inMinutes;
    final total = plan.fold(0, (sum, i) => sum + i.minutes);
    final next = plan.where((i) => !log.isDone(i.id)).firstOrNull;
    Widget row(PlanItem item) => ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(
            log.isDone(item.id) ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
            color: log.isDone(item.id) ? kSuccess : kMuted,
          ),
          title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text('${item.minutes} min · ${item.detail}', maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: item == next ? const Icon(Icons.play_circle_fill_rounded, color: kAccent, size: 32) : null,
          onTap: () => _start(item),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Icon(Icons.event_available_rounded, color: kAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text("Today's practice · $total min", style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              ),
              Text('$done/${plan.length}', style: const TextStyle(fontWeight: FontWeight.w800, color: kAccent)),
            ]),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(value: done / plan.length, minHeight: 8, color: kSuccess, backgroundColor: kSurfaceHigh),
            ),
            const SizedBox(height: 4),
            Text(
              done == plan.length ? 'All done today. Great work!' : '$minutes min played today',
              style: const TextStyle(color: kMuted, fontSize: 13),
            ),
            if (_open)
              for (final item in plan) row(item)
            else if (next != null)
              row(next),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _open = !_open),
                icon: Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded),
                label: Text(_open ? 'Just what\'s next' : 'Whole plan (${plan.length})'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
