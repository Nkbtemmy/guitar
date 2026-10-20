import 'dart:convert';

import '../music/notes.dart';
import '../practice/trackers.dart';

sealed class LessonStep {
  const LessonStep({this.title, this.body});

  final String? title;
  final String? body;

  /// Steps that need the microphone can be skipped (for a lower score).
  bool get listens => false;

  factory LessonStep.fromJson(Map<String, dynamic> j) {
    final title = j['title'] as String?;
    final body = j['body'] as String?;
    List<String> strings(String key) => List<String>.from(j[key] as List);
    return switch (j['type']) {
      'info' => InfoStep(title: title ?? '', body: body ?? '', chordId: j['chord'] as String?),
      'quiz' => QuizStep(
          question: j['question'] as String,
          options: strings('options'),
          answer: j['answer'] as int,
          explain: j['explain'] as String?),
      'tune' => TuneStep(title: title, body: body),
      'notes' => NotesStep(
          title: title ?? 'Play the notes',
          body: body,
          chordId: j['chord'] as String?,
          notes: [for (final n in j['notes'] as List) FretNote((n as List)[0] as int, n[1] as int)]),
      'chord' => ChordStep(chordId: j['chord'] as String, repeat: (j['repeat'] ?? 3) as int, body: body),
      'change' => ChangeStep(chordIds: strings('chords'), cycles: (j['cycles'] ?? 3) as int, body: body),
      'strum' => StrumStep(
          chordIds: strings('chords'),
          pattern: j['pattern'] as String,
          bpm: j['bpm'] as int,
          bars: j['bars'] as int,
          beatsPerBar: (j['beatsPerBar'] ?? 4) as int,
          body: body),
      'song' => SongStep(songId: j['song'] as String),
      final t => throw FormatException('Unknown step type "$t"'),
    };
  }
}

class InfoStep extends LessonStep {
  const InfoStep({required String super.title, required String super.body, this.chordId});

  final String? chordId;
}

class QuizStep extends LessonStep {
  const QuizStep({required this.question, required this.options, required this.answer, this.explain})
      : super(title: 'Quick check');

  final String question;
  final List<String> options;
  final int answer;
  final String? explain;
}

class TuneStep extends LessonStep {
  const TuneStep({super.title, super.body});

  @override
  bool get listens => true;
}

class NotesStep extends LessonStep {
  const NotesStep({required String super.title, super.body, required this.notes, this.chordId});

  final List<FretNote> notes;
  final String? chordId;

  @override
  bool get listens => true;
}

class ChordStep extends LessonStep {
  const ChordStep({required this.chordId, required this.repeat, super.body});

  final String chordId;
  final int repeat;

  @override
  bool get listens => true;
}

class ChangeStep extends LessonStep {
  const ChangeStep({required this.chordIds, required this.cycles, super.body});

  final List<String> chordIds;
  final int cycles;

  List<String> get sequence => [for (var c = 0; c < cycles; c++) ...chordIds];

  @override
  bool get listens => true;
}

class StrumStep extends LessonStep {
  const StrumStep({
    required this.chordIds,
    required this.pattern,
    required this.bpm,
    required this.bars,
    required this.beatsPerBar,
    super.body,
  });

  final List<String> chordIds;
  final String pattern;
  final int bpm, bars, beatsPerBar;

  StrumPattern get strumPattern => StrumPattern(pattern, beatsPerBar);

  String chordForBar(int bar) => chordIds[bar % chordIds.length];

  @override
  bool get listens => true;
}

class SongStep extends LessonStep {
  const SongStep({required this.songId});

  final String songId;

  @override
  bool get listens => true;
}

class SongLine {
  const SongLine({required this.lyrics, required this.bars});

  final String lyrics;
  final List<String> bars;
}

class Song {
  const Song({
    required this.id,
    required this.title,
    required this.credit,
    required this.bpm,
    required this.beatsPerBar,
    required this.pattern,
    required this.lines,
  });

  final String id, title, credit, pattern;
  final int bpm, beatsPerBar;
  final List<SongLine> lines;

  factory Song.fromJson(Map<String, dynamic> j) => Song(
        id: j['id'] as String,
        title: j['title'] as String,
        credit: j['credit'] as String,
        bpm: j['bpm'] as int,
        beatsPerBar: j['beatsPerBar'] as int,
        pattern: j['pattern'] as String,
        lines: [
          for (final l in j['lines'] as List)
            SongLine(lyrics: (l as Map)['lyrics'] as String, bars: List<String>.from(l['bars'] as List)),
        ],
      );

  List<String> get bars => [for (final l in lines) ...l.bars];

  Set<String> get chordIds => bars.toSet();

  StrumPattern get strumPattern => StrumPattern(pattern, beatsPerBar);
}

class Lesson {
  const Lesson({required this.id, required this.title, required this.summary, required this.steps});

  final String id, title, summary;
  final List<LessonStep> steps;

  factory Lesson.fromJson(Map<String, dynamic> j) => Lesson(
        id: j['id'] as String,
        title: j['title'] as String,
        summary: j['summary'] as String,
        steps: [for (final s in j['steps'] as List) LessonStep.fromJson(s as Map<String, dynamic>)],
      );
}

class Level {
  const Level({required this.id, required this.title, required this.subtitle, required this.icon, required this.lessons});

  final String id, title, subtitle, icon;
  final List<Lesson> lessons;

  factory Level.fromJson(Map<String, dynamic> j) => Level(
        id: j['id'] as String,
        title: j['title'] as String,
        subtitle: j['subtitle'] as String,
        icon: j['icon'] as String,
        lessons: [for (final l in j['lessons'] as List) Lesson.fromJson(l as Map<String, dynamic>)],
      );
}

class Curriculum {
  Curriculum({required this.levels, required List<Song> songs}) : songs = {for (final s in songs) s.id: s};

  factory Curriculum.fromJson(String source) {
    final j = jsonDecode(source) as Map<String, dynamic>;
    return Curriculum(
      levels: [for (final l in j['levels'] as List) Level.fromJson(l as Map<String, dynamic>)],
      songs: [for (final s in j['songs'] as List) Song.fromJson(s as Map<String, dynamic>)],
    );
  }

  final List<Level> levels;
  final Map<String, Song> songs;

  /// Every lesson in course order.
  late final List<Lesson> lessons = [for (final l in levels) ...l.lessons];

  Level levelOf(Lesson lesson) => levels.firstWhere((l) => l.lessons.contains(lesson));

  Song song(String id) => songs[id] ?? (throw ArgumentError('Unknown song "$id"'));

  /// The lesson that first features each song, used to unlock the songbook.
  String? lessonForSong(String songId) {
    for (final lesson in lessons) {
      if (lesson.steps.any((s) => s is SongStep && s.songId == songId)) return lesson.id;
    }
    return null;
  }
}
