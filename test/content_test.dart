import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fretwise/curriculum/models.dart';
import 'package:fretwise/music/chord_library.dart';
import 'package:fretwise/music/notes.dart';

void main() {
  final library = ChordLibrary.fromJson(File('assets/data/chords.json').readAsStringSync(),
      tipsJson: File('assets/data/chord_tips.json').readAsStringSync());
  final curriculum = Curriculum.fromJson(File('assets/data/curriculum.json').readAsStringSync());

  test('chord shapes are well-formed', () {
    for (final c in library.chords) {
      expect(c.frets.length, 6, reason: c.id);
      expect(c.fingers.length, 6, reason: c.id);
      expect(c.midiNotes.length, greaterThanOrEqualTo(3), reason: c.id);
      expect(c.tip, isNotNull, reason: '${c.id} has no tip');
      for (var i = 0; i < 6; i++) {
        if (c.frets[i] > 0) expect(c.fingers[i], inInclusiveRange(1, 4), reason: '${c.id} string ${6 - i}');
        if (c.frets[i] <= 0) expect(c.fingers[i], 0, reason: '${c.id} string ${6 - i}');
      }
    }
  });

  test('chord names match their notes', () {
    // Spot-check that shapes really spell the chord they claim to be.
    const expected = {
      'C': {0, 4, 7}, 'G': {7, 11, 2}, 'D': {2, 6, 9}, 'Em': {4, 7, 11}, 'Am': {9, 0, 4},
      'E7': {4, 8, 11, 2}, 'B7': {11, 3, 6, 9}, 'F': {5, 9, 0}, 'Bm': {11, 2, 6}, 'Bb': {10, 2, 5},
      'Cadd9': {0, 4, 7, 2}, 'Fmaj7': {5, 9, 0, 4}, 'C#m': {1, 4, 8}, 'G5': {7, 2},
    };
    expected.forEach((id, pcs) => expect(library.byId(id).pitchClasses, pcs, reason: id));
  });

  test('every lesson step is complete and references real chords and songs', () {
    expect(curriculum.levels.length, 12);
    final ids = <String>{};
    for (final lesson in curriculum.lessons) {
      expect(ids.add(lesson.id), isTrue, reason: 'duplicate ${lesson.id}');
      expect(lesson.steps, isNotEmpty, reason: lesson.id);
      for (final step in lesson.steps) {
        final where = '${lesson.id} ${step.runtimeType}';
        switch (step) {
          case InfoStep(:final body, :final chordId):
            expect((body ?? '').trim().split(' ').length, greaterThan(10),
                reason: '$where body missing (run tools/qwen_content.py)');
            if (chordId != null) expect(library.contains(chordId), isTrue, reason: where);
          case QuizStep(:final options, :final answer):
            expect(answer, inInclusiveRange(0, options.length - 1), reason: where);
          case NotesStep(:final notes, :final chordId):
            for (final n in notes) {
              expect(standardTuning.containsKey(n.string), isTrue, reason: where);
              expect(n.fret, inInclusiveRange(0, 15), reason: where);
            }
            if (chordId != null) expect(library.contains(chordId), isTrue, reason: where);
          case ChordStep(:final chordId):
            expect(library.contains(chordId), isTrue, reason: '$where $chordId');
          case ChangeStep(:final chordIds):
            for (final c in chordIds) {
              expect(library.contains(c), isTrue, reason: '$where $c');
            }
          case StrumStep(:final chordIds):
            for (final c in chordIds) {
              expect(library.contains(c), isTrue, reason: '$where $c');
            }
            expect(() => step.strumPattern, returnsNormally, reason: where);
          case SongStep(:final songId):
            expect(curriculum.songs.containsKey(songId), isTrue, reason: '$where $songId');
          case TuneStep():
            break;
        }
      }
    }
  });

  test('songs use known chords and valid patterns', () {
    for (final song in curriculum.songs.values) {
      for (final c in song.chordIds) {
        expect(library.contains(c), isTrue, reason: '${song.id} uses $c');
      }
      expect(() => song.strumPattern, returnsNormally, reason: song.id);
      expect(curriculum.lessonForSong(song.id), isNotNull, reason: '${song.id} is not in any lesson');
    }
  });

  test('chords are introduced before songs and drills use them', () {
    final introduced = <String>{};
    for (final lesson in curriculum.lessons) {
      for (final step in lesson.steps) {
        if (step is ChordStep) introduced.add(step.chordId);
        if (step is InfoStep && step.chordId != null) introduced.add(step.chordId!);
        final used = switch (step) {
          ChangeStep(:final chordIds) => chordIds,
          StrumStep(:final chordIds) => chordIds,
          SongStep(:final songId) => curriculum.song(songId).chordIds.toList(),
          _ => const <String>[],
        };
        for (final c in used) {
          expect(introduced, contains(c), reason: '${lesson.id} uses $c before it is taught');
        }
      }
    }
  });
}
