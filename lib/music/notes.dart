import 'dart:math' as math;

const noteNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

/// MIDI numbers of the open strings in standard tuning, indexed by string number (1 = high E).
const standardTuning = <int, int>{6: 40, 5: 45, 4: 50, 3: 55, 2: 59, 1: 64};

const stringLetters = <int, String>{6: 'E', 5: 'A', 4: 'D', 3: 'G', 2: 'B', 1: 'e'};

double midiToFreq(num midi) => 440.0 * math.pow(2, (midi - 69) / 12);

double freqToMidi(double freq) => 69 + 12 * math.log(freq / 440.0) / math.ln2;

int pitchClass(int midi) => midi % 12;

String noteName(int midi) => noteNames[midi % 12];

String noteNameWithOctave(int midi) => '${noteNames[midi % 12]}${midi ~/ 12 - 1}';

int midiAt(int string, int fret) => standardTuning[string]! + fret;

/// How the six strings are tuned: the note each open string sounds (string 1 = high e).
class Tuning {
  const Tuning(this.name, this.notes);

  final String name;
  final Map<int, int> notes;

  static const standard = Tuning('Standard', standardTuning);
  static const dropD = Tuning('Drop D', {6: 38, 5: 45, 4: 50, 3: 55, 2: 59, 1: 64});
  static const halfStepDown = Tuning('Half step down', {6: 39, 5: 44, 4: 49, 3: 54, 2: 58, 1: 63});
  static const wholeStepDown = Tuning('Whole step down', {6: 38, 5: 43, 4: 48, 3: 53, 2: 57, 1: 62});
  static const openG = Tuning('Open G', {6: 38, 5: 43, 4: 50, 3: 55, 2: 59, 1: 62});
  static const openD = Tuning('Open D', {6: 38, 5: 45, 4: 50, 3: 54, 2: 57, 1: 62});
  static const dadgad = Tuning('DADGAD', {6: 38, 5: 45, 4: 50, 3: 55, 2: 57, 1: 62});

  static const all = [standard, dropD, halfStepDown, wholeStepDown, openG, openD, dadgad];

  /// The open strings' notes, low to high: "D A D G B E".
  String get spelled => [for (var s = 6; s >= 1; s--) noteName(notes[s]!)].join(' ');

  int midiAt(int string, int fret) => notes[string]! + fret;

  /// The tuning a song names: "Drop D", "half step down", "Eb", "DADGAD", "D A D G B E"…
  static Tuning? named(String name) {
    final key = name.toLowerCase().replaceAll(RegExp(r'[^a-z#]'), '');
    const aliases = {
      'e': standard, 'estandard': standard, 'normal': standard, //
      'eb': halfStepDown, 'ebstandard': halfStepDown, 'halfstep': halfStepDown, 'halfstepdown': halfStepDown,
      'd': wholeStepDown, 'dstandard': wholeStepDown, 'wholestep': wholeStepDown, 'wholestepdown': wholeStepDown,
    };
    for (final t in all) {
      final spelled = t.spelled.toLowerCase().replaceAll(' ', '');
      if (key == t.name.toLowerCase().replaceAll(' ', '') || key == spelled) return t;
    }
    return aliases[key];
  }

  @override
  bool operator ==(Object other) => other is Tuning && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// A position on the fretboard. [string] 1..6 (6 = low E), [fret] 0 = open.
class FretNote {
  const FretNote(this.string, this.fret);

  final int string;
  final int fret;

  int get midi => midiAt(string, fret);
  double get frequency => midiToFreq(midi);

  String get label => fret == 0 ? 'String $string open' : 'String $string, fret $fret';

  @override
  bool operator ==(Object other) => other is FretNote && other.string == string && other.fret == fret;

  @override
  int get hashCode => Object.hash(string, fret);

  @override
  String toString() => 'FretNote($string, $fret)';
}
