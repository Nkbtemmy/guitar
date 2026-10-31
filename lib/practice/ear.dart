import 'dart:math' as math;

import '../music/notes.dart';
import '../sheets/tab_sequence.dart';

/// Notes a beginner can find without looking: the C major scale on the top three strings, open
/// position (G A B C D E F G).
const echoNotes = [
  FretNote(3, 0), FretNote(3, 2), FretNote(2, 0), FretNote(2, 1), //
  FretNote(2, 3), FretNote(1, 0), FretNote(1, 1), FretNote(1, 3),
];

/// A phrase to hear and play back: [length] notes from [echoNotes], each a step or two from the
/// last, so it sings like a tune rather than jumping about.
List<FretNote> echoPhrase(int length, math.Random random) {
  var at = random.nextInt(echoNotes.length);
  final phrase = [echoNotes[at]];
  while (phrase.length < length) {
    final next = (at + const [-2, -1, 1, 2][random.nextInt(4)]).clamp(0, echoNotes.length - 1);
    if (next == at) continue;
    at = next;
    phrase.add(echoNotes[at]);
  }
  return phrase;
}

/// [notes] as quarter notes in a tab, to play to the learner.
TabSequence phraseTab(List<FretNote> notes) => TabSequence(
      [for (var i = 0; i < notes.length; i++) TabEvent(i * TabSequence.columnsPerBeat, {notes[i].string: notes[i].fret})],
      length: notes.length * TabSequence.columnsPerBeat,
    );

/// Major and minor chords to tell apart by ear, as chord library ids.
const majorChords = ['A', 'C', 'D', 'E', 'G', 'F'];
const minorChords = ['Am', 'Dm', 'Em', 'Bm', 'F#m', 'Cm'];
