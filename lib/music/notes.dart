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
