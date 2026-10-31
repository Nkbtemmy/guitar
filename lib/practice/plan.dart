import '../curriculum/models.dart';
import '../progress/practice_log.dart';

/// What a plan item opens.
enum PlanKind { tune, fretboard, ear, changes, spot, metronome, lesson, songs }

/// One part of today's practice.
class PlanItem {
  const PlanItem(this.kind, this.title, this.detail, this.minutes, {this.spot, this.lesson, this.pair});

  final PlanKind kind;
  final String title, detail;
  final int minutes;

  /// What it practises, when it's a weak spot, a lesson or a chord pair.
  final WeakSpot? spot;
  final Lesson? lesson;
  final (String, String)? pair;

  /// Ticked off by this, for the day.
  String get id => kind.name;
}

/// Today's practice: about a quarter of an hour, the way a teacher would lay it out. Tune up,
/// warm up (the fretboard one day, ear training the next), drill a chord change, fix the part
/// that keeps going wrong, then move the course on.
List<PlanItem> dailyPlan({required DateTime day, Lesson? nextLesson, (String, String)? pair, WeakSpot? spot}) {
  final (a, b) = pair ?? ('C', 'G');
  return [
    const PlanItem(PlanKind.tune, 'Tune up', 'Every string, before anything else', 1),
    day.day.isEven
        ? const PlanItem(PlanKind.fretboard, 'Warm up: fretboard notes', 'A minute naming the notes on the neck', 2)
        : const PlanItem(PlanKind.ear, 'Warm up: ear training', 'Hear it, then play it back', 2),
    PlanItem(PlanKind.changes, 'Chord changes: $a – $b', 'One minute, beat your best', 2, pair: (a, b)),
    if (spot != null)
      PlanItem(PlanKind.spot, 'Fix: ${spot.title}', spot.detail, 3, spot: spot)
    else
      const PlanItem(PlanKind.metronome, 'Strum in time', 'Your strumming pattern with the metronome', 3),
    if (nextLesson != null)
      PlanItem(PlanKind.lesson, 'Lesson: ${nextLesson.title}', 'Next in the course', 7, lesson: nextLesson)
    else
      const PlanItem(PlanKind.songs, 'Play a song', 'Pick one from the songbook and play along', 7),
  ];
}
