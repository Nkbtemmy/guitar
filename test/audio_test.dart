import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guitaro/audio/analysis.dart';
import 'package:guitaro/audio/chord_matcher.dart';
import 'package:guitaro/audio/synth.dart';
import 'package:guitaro/music/chord_library.dart';
import 'package:guitaro/music/notes.dart';
import 'package:guitaro/practice/trackers.dart';

const sr = 44100;

ChordLibrary loadLibrary() => ChordLibrary.fromJson(File('assets/data/chords.json').readAsStringSync());

Float64List window(Float32List s, int start, int size) =>
    Float64List.fromList([for (var i = 0; i < size; i++) s[start + i].toDouble()]);

void addNoise(Float32List s, double amp, {int seed = 3}) {
  final r = math.Random(seed);
  for (var i = 0; i < s.length; i++) {
    s[i] += amp * (r.nextDouble() * 2 - 1);
  }
}

void main() {
  final synth = GuitarSynth();
  final yin = YinPitchDetector(sampleRate: sr);

  group('synth + YIN pitch', () {
    test('every string, frets 0-12, is synthesized and detected within 8 cents', () {
      for (var string = 1; string <= 6; string++) {
        for (var fret = 0; fret <= 12; fret++) {
          final midi = midiAt(string, fret);
          final s = synth.pluck(midiToFreq(midi), seconds: 0.5, seed: string * 100 + fret);
          final p = yin.detect(window(s, 4410, 2048));
          expect(p, isNotNull, reason: 'no pitch for string $string fret $fret');
          final cents = (p!.midi - midi) * 100;
          expect(cents.abs(), lessThan(8), reason: 'string $string fret $fret off by $cents cents');
          expect(p.clarity, greaterThan(0.85));
        }
      }
    });

    test('silence and white noise give no confident pitch', () {
      expect(yin.detect(Float64List(2048)), isNull);
      final noise = Float32List(2048);
      addNoise(noise, 0.5);
      final p = yin.detect(window(noise, 0, 2048));
      expect(p == null || p.clarity < 0.85, isTrue);
    });
  });

  group('chord recognition', () {
    final library = loadLibrary();
    final matcher = ChordMatcher(library.chords);
    final spectrum = SpectrumAnalyzer(sampleRate: sr);

    List<SpectralPeak> peaksOf(List<int> notes, {double noise = 0, int seed = 7}) {
      final s = synth.strum(notes, seconds: 0.6, seed: seed);
      if (noise > 0) addNoise(s, noise);
      return spectrum.peaks(window(s, 8820, 8192));
    }

    test('each library chord is recognised when strummed', () {
      final failures = <String>[];
      for (final chord in library.chords) {
        final v = matcher.verify(peaksOf(chord.midiNotes), chord);
        if (!v.matches) failures.add('${chord.id} (score ${v.score.toStringAsFixed(3)}, best ${v.best.id})');
      }
      expect(failures, isEmpty);
    });

    test('recognition survives background noise', () {
      for (final id in ['Em', 'C', 'G', 'D', 'Am', 'F', 'Bm']) {
        final chord = library.byId(id);
        expect(matcher.verify(peaksOf(chord.midiNotes, noise: 0.02, seed: 21), chord).matches, isTrue, reason: id);
      }
    });

    test('the wrong chord is rejected', () {
      final failures = <String>[];
      const common = ['Em', 'E', 'Am', 'A', 'D', 'G', 'C', 'Dm', 'E7', 'A7', 'D7', 'B7', 'F', 'Bm', 'Fmaj7'];
      for (final played in common) {
        final peaks = peaksOf(library.byId(played).midiNotes);
        for (final expected in common) {
          if (expected == played) continue;
          if (matcher.verify(peaks, library.byId(expected)).matches) failures.add('$played accepted as $expected');
        }
      }
      expect(failures, isEmpty);
    });

    test('ranking puts the played chord (or a same-note voicing) first', () {
      for (final id in ['Em', 'A', 'D', 'G', 'C', 'E7', 'Dsus4', 'Cadd9', 'G5']) {
        final chord = library.byId(id);
        final top = matcher.rank(peaksOf(chord.midiNotes)).first.chord;
        expect(top.pitchClasses, chord.pitchClasses, reason: '$id ranked ${top.id} first');
      }
    });
  });

  group('onsets', () {
    test('detects strums at the right times and nothing else', () {
      final library = loadLibrary();
      final times = [0.5, 1.0, 1.25, 1.75, 2.0, 2.25, 2.5, 3.1];
      final s = Float32List((3.8 * sr).round());
      for (var i = 0; i < times.length; i++) {
        synth.addStrum(s, (times[i] * sr).round(), library.byId(i.isEven ? 'G' : 'C').midiNotes,
            down: i.isEven, seed: i + 1, gain: 0.25);
      }
      addNoise(s, 0.002);
      final onsets = OnsetDetector(sampleRate: sr).process(s);
      expect(onsets.length, times.length, reason: 'onsets: $onsets');
      for (var i = 0; i < times.length; i++) {
        expect((onsets[i] - times[i]).abs(), lessThan(0.03), reason: 'strum $i at ${times[i]} found ${onsets[i]}');
      }
    });
  });

  test('folk pattern on one chord: every down and up strum is found, with the click track playing', () {
    final library = loadLibrary();
    final g = library.byId('G').midiNotes;
    const bpm = 80;
    final pattern = StrumPattern('D-DU-UDU', 4);
    final times = pattern.expectedTimes(bpm: bpm, bars: 2);
    final s = synth.clickTrack(bpm: bpm, beatsPerBar: 4, bars: 3);
    for (var i = 0; i < s.length; i++) {
      s[i] *= 0.5; // the app plays clicks at half volume
    }
    final hits = [...pattern.hits, ...pattern.hits];
    for (var i = 0; i < times.length; i++) {
      final down = hits[i].direction == StrumDirection.down;
      synth.addStrum(s, (times[i] * sr).round(), down ? g : g.sublist(3), down: down, seed: i + 5, gain: down ? 0.3 : 0.2);
    }
    final onsets = OnsetDetector(sampleRate: sr).process(s);
    final result = TimingScorer.score(times, onsets);
    expect(result.accuracy, 1.0, reason: 'onsets: $onsets');
    expect(result.extra, 0, reason: 'onsets: $onsets');
  });

  test('metronome clicks are not mistaken for strums', () {
    final library = loadLibrary();
    final clicks = synth.clickTrack(bpm: 120, beatsPerBar: 4, bars: 2);
    final strumTimes = [0.25, 1.25, 2.75];
    for (final t in strumTimes) {
      synth.addStrum(clicks, (t * sr).round(), library.byId('G').midiNotes, gain: 0.3);
    }
    final onsets = OnsetDetector(sampleRate: sr).process(clicks);
    expect(onsets.length, strumTimes.length, reason: 'onsets: $onsets');
    for (var i = 0; i < strumTimes.length; i++) {
      expect((onsets[i] - strumTimes[i]).abs(), lessThan(0.03));
    }
    final clickOnly = synth.clickTrack(bpm: 100, beatsPerBar: 4, bars: 2);
    expect(OnsetDetector(sampleRate: sr).process(clickOnly), isEmpty);
    expect(AudioAnalyzer().add(clickOnly).where((f) => f.peaks.isNotEmpty && f.pitch != null && f.pitch!.clarity > 0.85),
        isEmpty);
  });

  group('AudioAnalyzer', () {
    test('emits one frame per hop regardless of chunk size, with pitch for a held note', () {
      final s = synth.pluck(midiToFreq(57), seconds: 1.0);
      final analyzer = AudioAnalyzer();
      final frames = <AnalysisFrame>[];
      var i = 0;
      for (final chunk in [100, 3000, 512, 9000, 4096, 1]) {
        if (i >= s.length) break;
        final end = math.min(s.length, i + chunk);
        frames.addAll(analyzer.add(Float32List.sublistView(s, i, end)));
        i = end;
      }
      frames.addAll(analyzer.add(Float32List.sublistView(s, i)));
      expect(frames.length, s.length ~/ 2048);
      final voiced = frames.where((f) => f.pitch != null && f.pitch!.clarity > 0.85).toList();
      expect(voiced, isNotEmpty);
      expect((voiced.last.pitch!.midi - 57).abs(), lessThan(0.1));
      expect(frames.expand((f) => f.onsets).length, 1);
    });

    test('quiet input is gated', () {
      final s = Float32List(sr ~/ 2);
      addNoise(s, 0.001);
      final frames = AudioAnalyzer().add(s);
      expect(frames.every((f) => !f.hasSound), isTrue);
    });
  });

  test('WAV header is valid', () {
    final wav = synth.toWav(Float32List(100));
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(wav.length, 44 + 200);
  });
}
