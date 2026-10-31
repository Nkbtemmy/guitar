import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guitaro/audio/analysis.dart';
import 'package:guitaro/audio/synth.dart';
import 'package:guitaro/music/chord_library.dart';
import 'package:guitaro/music/notes.dart';
import 'package:guitaro/sheets/chord_finder.dart';
import 'package:guitaro/sheets/chord_sheet.dart';
import 'package:guitaro/sheets/melody_finder.dart';

const sr = 44100;

/// Amazing Grace as sung (D4..D5), in 3/4 at 80: (MIDI, beats).
const amazingGrace = [
  (62, 1.0), (67, 2.0), (71, .5), (67, .5), (71, 2.0), (69, 1.0), (67, 2.0), (64, 1.0), (62, 2.0), (62, 1.0), //
  (67, 2.0), (71, .5), (67, .5), (71, 2.0), (69, 1.0), (74, 2.0), (71, 1.0), (74, 1.5), (71, .5), (74, .5), //
  (71, .5), (67, 2.0), (62, 1.0), (64, 1.5), (67, .5), (67, .5), (64, .5), (62, 2.0), (62, 1.0), (67, 2.0), //
  (71, .5), (67, .5), (71, 2.0), (69, 1.0), (67, 3.0),
];
const amazingGraceChords = [
  ('G', 4), ('G7', 3), ('C', 3), ('G', 3), ('G', 3), ('G', 3), ('D', 3), ('G', 3), ('G7', 3), ('C', 3), ('G', 3), //
  ('Em', 3), ('D', 3), ('G', 3),
];

/// Ode to Joy (E4..G4), 4/4.
const odeToJoy = [
  (64, 1.0), (64, 1.0), (65, 1.0), (67, 1.0), (67, 1.0), (65, 1.0), (64, 1.0), (62, 1.0), (60, 1.0), (60, 1.0), //
  (62, 1.0), (64, 1.0), (64, 1.5), (62, .5), (62, 2.0),
];

typedef Truth = List<({int midi, double start})>;

void main() {
  final synth = GuitarSynth();
  final library = ChordLibrary.fromJson(File('assets/data/chords.json').readAsStringSync());

  /// [tune] at [bpm], sung (a voice with vibrato) or picked on one string at a time an octave
  /// down, over strummed [chords] and a bass when given. Returns the audio and the true notes.
  (Float32List, Truth) perform(List<(int, double)> tune, int bpm,
      {bool sung = true, List<(String, int)> chords = const []}) {
    final beat = 60 / bpm;
    final length = tune.fold(0.0, (a, n) => a + n.$2) * beat + 2;
    final out = Float32List((length * sr).round());
    final truth = <({int midi, double start})>[];
    var t = 0.0;
    for (final (midi, beats) in tune) {
      final m = sung ? midi : midi - 12;
      truth.add((midi: m, start: t));
      final n = (beats * beat * sr).round();
      if (sung) {
        final f = midiToFreq(m);
        var phase = 0.0;
        for (var i = 0; i < n * 0.97; i++) {
          final s = i / sr;
          final env = math.min(1.0, s / 0.05) * math.min(1.0, (n * 0.97 - i) / (0.04 * sr));
          phase += 2 * math.pi * f * math.pow(2, 0.25 / 12 * math.sin(2 * math.pi * 5.5 * s) * math.min(1, s / 0.3)) / sr;
          final v = math.sin(phase) + 0.6 * math.sin(2 * phase) + 0.35 * math.sin(3 * phase) + 0.2 * math.sin(4 * phase);
          out[(t * sr).round() + i] += 0.22 * env * v;
        }
      } else {
        synth.addNote(out, (t * sr).round(), m, gain: 0.8, seed: truth.length, lengthSamples: n);
      }
      t += beats * beat;
    }
    var at = 0.0, k = 0;
    for (final (id, beats) in chords) {
      final notes = library.byId(id).midiNotes;
      for (var b = 0; b < beats; b++, k++) {
        final start = ((at + b * beat) * sr).round();
        synth.addStrum(out, start, notes, seed: k, gain: 0.3, lengths: [for (final _ in notes) (beat * sr).round()]);
        synth.addNote(out, start, notes.first - 12 < 28 ? notes.first : notes.first - 12,
            gain: 0.5, seed: 100 + k, lengthSamples: (beat * 0.9 * sr).round());
      }
      at += beats * beat;
    }
    GuitarSynth.normalize(out, 0.6);
    return (out, truth);
  }

  List<AnalysisFrame> hear(Float32List audio) => AudioAnalyzer(gate: 0.006).add(audio);

  /// Share of the true notes found (onset within 0.1 s, same pitch), and of the found that are true.
  ({double recall, double precision}) match(Truth truth, List<MelodyNote> found) {
    final used = List.filled(found.length, false);
    var hits = 0;
    for (final n in truth) {
      for (var i = 0; i < found.length; i++) {
        if (!used[i] && found[i].midi == n.midi && (found[i].start - n.start).abs() <= 0.1) {
          used[i] = true;
          hits++;
          break;
        }
      }
    }
    return (recall: hits / truth.length, precision: found.isEmpty ? 0 : hits / found.length);
  }

  test('a melody picked on single strings is written down note for note, repeated notes included', () {
    final (audio, truth) = perform(odeToJoy, 100, sung: false);
    final finder = MelodyFinder();
    for (final f in hear(audio)) {
      finder.add(f, f.time);
    }
    final m = match(truth, finder.tune);
    expect(m.precision, greaterThanOrEqualTo(0.95));
    expect(m.recall, greaterThanOrEqualTo(0.85));
  });

  test('a sung melody is found over strummed chords and a bass', () {
    final (audio, truth) = perform(amazingGrace, 80, chords: amazingGraceChords);
    final finder = MelodyFinder();
    for (final f in hear(audio)) {
      finder.add(f, f.time);
    }
    final m = match(truth, finder.tune);
    expect(m.precision, greaterThanOrEqualTo(0.85));
    expect(m.recall, greaterThanOrEqualTo(0.85));
  });

  test('strummed chords alone have no tune to write down', () {
    final (audio, _) = perform(const [(0, 16.0)], 90, chords: const [('G', 4), ('C', 4), ('D', 4), ('Em', 4)]);
    final finder = ChordFinder();
    for (final f in hear(audio)) {
      finder.add(f);
    }
    expect(finder.melody.tune, isEmpty);
    expect(finder.toSheetText(), isNot(contains('start_of_tab')));
  });

  test('the song becomes a sheet: chords, then the melody as tab in time, in its own metre', () {
    final (audio, _) = perform(amazingGrace, 80, chords: amazingGraceChords);
    final finder = ChordFinder();
    for (final f in hear(audio)) {
      finder.add(f);
    }
    final sheet = ChordSheet.parse(finder.toSheetText(), id: 'found');
    expect(sheet.tempo, inInclusiveRange(78, 82));
    expect(sheet.beatsPerBar, 3);
    expect(sheet.chordNames, ['G', 'C', 'D', 'Em']);
    // The tab has the tune (an octave down, the way guitar is written), note for note in order.
    final tab = sheet.tabs.single;
    final heard = [for (final e in tab.events) e.frets.entries.map((s) => midiAt(s.key, s.value)).first];
    final sung = [for (final (m, _) in amazingGrace) m - 12];
    expect(_commonInOrder(heard, sung), greaterThanOrEqualTo(32), reason: '$heard');
    // In time over the whole song: first to last note spans the hymn's length, in sixteenths
    // at the tempo written (40 beats from the pickup to the last "see").
    final span = amazingGrace.take(amazingGrace.length - 1).fold(0.0, (a, n) => a + n.$2) * 4;
    expect(tab.events.last.column - tab.events.first.column, inInclusiveRange(span - 2, span + 2));
  });

  test('tempo from onsets, even with some missing and a little loose', () {
    final rnd = math.Random(2);
    final onsets = [
      for (var t = 0.0; t < 30; t += 60 / 96 / 2)
        if (rnd.nextDouble() < 0.8) t + (rnd.nextDouble() - 0.5) * 0.03,
    ];
    expect(tempoOf(onsets), 96);
    expect(tempoOf([0, 0.5, 1]), isNull);
  });

  test('a melody written as tab plays back as the same notes, in the same rhythm, under its chords', () {
    // Ode to Joy at 100: a beat is 0.6 s.
    var t = 1.0;
    final notes = <MelodyNote>[];
    for (final (midi, beats) in odeToJoy) {
      notes.add(MelodyNote(midi, t + 0.02, t + beats * 0.6));
      t += beats * 0.6;
    }
    final text = melodyTab(notes, bpm: 100, downbeat: 1.0, chords: const [(1.0, 'C'), (3.4, 'G'), (5.8, 'C')]);
    final tab = ChordSheet.parse('{tempo: 100}\n$text', id: 'tab').tabs.single;
    expect([for (final e in tab.events) e.frets.entries.map((s) => midiAt(s.key, s.value)).first],
        [for (final n in notes) n.midi - 12]);
    // Quarters four sixteenths apart, the dotted quarter six, the eighth two.
    expect([for (var i = 1; i < tab.events.length; i++) tab.events[i].column - tab.events[i - 1].column],
        [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 2]);
    expect([for (final b in tab.barStarts) tab.labels[b]].nonNulls, ['G', 'C']);
    // Open position, no frets past the 5th, for a tune in this range.
    expect(tab.events.every((e) => e.frets.values.every((f) => f <= 5)), isTrue);
  });
}

/// The longest run of [a] found in order in [b] (not necessarily together).
int _commonInOrder(List<int> a, List<int> b) {
  final d = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      d[i][j] = a[i - 1] == b[j - 1] ? d[i - 1][j - 1] + 1 : math.max(d[i - 1][j], d[i][j - 1]);
    }
  }
  return d[a.length][b.length];
}
