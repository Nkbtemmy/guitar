import '../curriculum/models.dart';
import '../progress/practice_log.dart';

/// What a plan item opens.
enum PlanKind { tune, fretboard, ear, changes, spot, metronome, homework, lesson, songs }

/// One part of today's practice.
class PlanItem {
  const PlanItem(this.kind, this.title, this.detail, this.minutes, {this.spot, this.lesson, this.pair, this.homework});

  final PlanKind kind;
  final String title, detail;
  final int minutes;

  /// What it practises, when it's a weak spot, a lesson, a chord pair or homework.
  final WeakSpot? spot;
  final Lesson? lesson;
  final (String, String)? pair;
  final Homework? homework;

  /// Ticked off by this, for the day.
  String get id => kind.name;
}

/// Today's practice, laid out the way a teacher would in [minutes] (the learner's goal): tune
/// up, then the course, and around it, as time allows and most needed first, the [homework],
/// the part that keeps going wrong ([spot]), a chord change and a warm-up (the fretboard one
/// day, ear training the next). Time over goes to the lesson, and past ten minutes of it, to a
/// song.
List<PlanItem> dailyPlan({
  required DateTime day,
  int minutes = 15,
  Lesson? nextLesson,
  (String, String)? pair,
  WeakSpot? spot,
  Homework? homework,
}) {
  final (a, b) = pair ?? ('C', 'G');
  const lessonAtLeast = 4, lessonAtMost = 10;
  var left = minutes - 1 - lessonAtLeast;
  bool fits(int m) {
    if (m > left) return false;
    left -= m;
    return true;
  }

  final withHomework = homework != null && fits(3);
  final withFix = fits(3);
  final withChanges = fits(2);
  final withWarmup = fits(2);
  final lesson = (lessonAtLeast + left).clamp(lessonAtLeast, lessonAtMost);
  final song = lessonAtLeast + left - lesson;
  return [
    const PlanItem(PlanKind.tune, 'Tune up', 'Every string, before anything else', 1),
    if (withWarmup)
      day.day.isEven
          ? const PlanItem(PlanKind.fretboard, 'Warm up: fretboard notes', 'A minute naming the notes on the neck', 2)
          : const PlanItem(PlanKind.ear, 'Warm up: ear training', 'Hear it, then play it back', 2),
    if (withChanges) PlanItem(PlanKind.changes, 'Chord changes: $a – $b', 'One minute, beat your best', 2, pair: (a, b)),
    if (withFix)
      spot != null
          ? PlanItem(PlanKind.spot, 'Fix: ${spot.title}', spot.detail, 3, spot: spot)
          : const PlanItem(PlanKind.metronome, 'Strum in time', 'Your strumming pattern with the metronome', 3),
    if (withHomework)
      PlanItem(PlanKind.homework, 'Homework: ${homework.title}', 'Play it through at ${(homework.tempo * 100).round()}% speed', 3,
          homework: homework),
    if (nextLesson != null)
      PlanItem(PlanKind.lesson, 'Lesson: ${nextLesson.title}', 'Next in the course', lesson, lesson: nextLesson)
    else
      PlanItem(PlanKind.songs, 'Play a song', 'Pick one from the songbook and play along', lesson + song),
    if (song > 0 && nextLesson != null) PlanItem(PlanKind.songs, 'Play a song', 'Pick one from the songbook and play along', song),
  ];
}
