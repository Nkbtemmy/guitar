import '../curriculum/models.dart';
import '../progress/practice_log.dart';
import '../progress/progress_store.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String shortDate(DateTime t) => '${t.day} ${_months[t.month - 1]}';

String _duration(Duration d) =>
    d.inHours > 0 ? '${d.inHours} h ${d.inMinutes % 60} min' : '${d.inMinutes} min';

/// A student's progress as plain text, short enough for a chat message to a teacher or parent:
/// the course, practice time, chord changes, games, homework, and what to practise next.
String progressReport({
  required String name,
  required ProgressStore progress,
  required PracticeLog log,
  required Curriculum curriculum,
  required DateTime now,
}) {
  final lines = <String>[];
  final who = name.trim().isEmpty ? '' : ' · ${name.trim()}';
  lines.add('Guitaro progress$who · ${shortDate(now)} ${now.year}');
  lines.add('');

  final next = progress.nextLesson(curriculum);
  final level = next == null ? 'course complete' : 'now on "${next.title}" (${curriculum.levelOf(next).title})';
  lines.add('Course: ${progress.lessonsCompleted} of ${curriculum.lessons.length} lessons, ${progress.totalStars} stars, $level');

  final week = log.practicedOver(7, now: now);
  lines.add('Practice: ${_duration(week)} in the last 7 days · ${progress.streak(now)}-day streak');

  final pairs = log.changePairs;
  if (pairs.isNotEmpty) {
    final parts = [
      for (final (a, b) in pairs.take(3))
        if (log.changeRuns(a, b) case final runs when runs.isNotEmpty)
          '$a – $b best ${log.bestChanges(a, b)}/min${runs.length > 1 ? ' (first ${runs.first.count})' : ''}',
    ];
    lines.add('Chord changes: ${parts.join(' · ')}');
  }

  final games = [
    if (log.best('fretboard:name') case final b?) 'Fretboard (name it) $b',
    if (log.best('fretboard:play') case final b?) 'Fretboard (play it) $b',
    if (log.best('ear:quality') case final b?) 'Major or minor $b/10',
    if (log.best('ear:echo') case final b?) 'Play it back $b',
  ];
  if (games.isNotEmpty) lines.add('Best scores: ${games.join(' · ')}');

  final homework = log.homework;
  if (homework.isNotEmpty) {
    lines.add('Homework:');
    for (final h in homework) {
      final due = h.due == null ? '' : ' by ${shortDate(h.due!)}';
      lines.add('  ${h.done ? '✓' : '○'} ${h.title} at ${(h.tempo * 100).round()}% speed$due${h.done ? ', done' : ''}');
    }
  }

  final spots = log.weakSpots(now: now);
  if (spots.isNotEmpty) {
    lines.add('Practise next:');
    for (final s in spots.take(3)) {
      lines.add('  ${s.title}, ${s.detail.split(':').first.toLowerCase()} (missed ${s.misses} of ${s.misses + s.hits})');
    }
  }
  return lines.join('\n');
}
