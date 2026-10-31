import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitaro/audio/analysis.dart';
import 'package:guitaro/audio/chord_matcher.dart';
import 'package:guitaro/audio/sound_player.dart';
import 'package:guitaro/audio/synth.dart';
import 'package:guitaro/music/chord_library.dart';
import 'package:guitaro/practice/trackers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final folk = StrumPattern('D-DU-UDU', 4);
  final library = ChordLibrary.fromJson(File('assets/data/chords.json').readAsStringSync());
  final synth = GuitarSynth();

  test('a track mixed a block at a time is sample-for-sample the same as one long buffer', () {
    final rnd = math.Random(5);
    const length = 44100 * 3 + 123; // not a whole number of blocks
    final buffer = Float32List(length);
    final track = SynthTrack(synth, length);
    for (var i = 0; i < 40; i++) {
      final start = rnd.nextInt(length + 1000); // some past the end, which must add nothing
      final ring = rnd.nextBool() ? null : rnd.nextInt(30000) - 500;
      if (i == 25) {
        GuitarSynth.normalize(buffer);
        track.normalize();
      }
      if (i % 3 == 0) {
        synth.addClick(buffer, start, accent: i.isEven);
        track.addClick(start, accent: i.isEven);
      } else if (i % 3 == 1) {
        final notes = [40 + rnd.nextInt(10), 50 + rnd.nextInt(10), 60 + rnd.nextInt(10)];
        final lengths = [ring, null, ring == null ? 5000 : null];
        synth.addStrum(buffer, start, notes, down: i.isEven, seed: i, gain: 0.5, lengths: lengths);
        track.addStrum(start, notes, down: i.isEven, seed: i, gain: 0.5, lengths: lengths);
      } else {
        synth.addNote(buffer, start, 45 + i, seed: i, lengthSamples: ring);
        track.addNote(start, 45 + i, seed: i, lengthSamples: ring);
      }
    }
    final streamed = track.renderAll();
    var maxDiff = 0.0;
    for (var i = 0; i < length; i++) {
      maxDiff = math.max(maxDiff, (streamed[i] - buffer[i]).abs());
    }
    expect(maxDiff, 0);
    expect(buffer.any((v) => v != 0), isTrue);
  });

  group('strummed bars', () {
    test('a chord change damps the strings the new chord frets differently', () {
      // G rings a low G (string 6) that C mutes. Left ringing, it made C fail to match.
      final g = library.byId('G'), c = library.byId('C');
      const bpm = 90;
      final out = SoundPlayer.renderBars(synth, [g, c], strum: folk, bpm: bpm).renderAll();
      final spectrum = SpectrumAnalyzer(sampleRate: synth.sampleRate);
      final matcher = ChordMatcher(library.chords);
      for (final into in [0.3, 0.6, 0.9]) {
        final end = ((1 + into) * 4 * 60 / bpm * synth.sampleRate).round();
        final peaks = spectrum.peaks(Float64List.fromList([for (var i = end - 8192; i < end; i++) out[i].toDouble()]));
        final lowG = peaks.where((p) => (p.frequency / 98.0 - 1).abs() < 0.02);
        expect(lowG.every((p) => p.magnitude < 0.01 * peaks.first.magnitude), isTrue, reason: '$into into the C bar');
        expect(matcher.verify(peaks, c).matches, isTrue, reason: '$into into the C bar');
      }
    });

    test('rendering time grows with song length, not its square', () {
      final bars = [for (var i = 0; i < 64; i++) library.byId(const ['G', 'C', 'D', 'Em'][i % 4])];
      int time(int n) {
        var best = 1 << 62;
        for (var r = 0; r < 3; r++) {
          final sw = Stopwatch()..start();
          SoundPlayer.renderBars(synth, bars.sublist(0, n), strum: folk, bpm: 90).render((_) {});
          if (sw.elapsedMicroseconds < best) best = sw.elapsedMicroseconds;
        }
        return best;
      }

      time(8); // warm up
      final ratio = time(64) / time(8);
      // 8x the bars: ~8x the time when linear, ~40-60x when every note rings to the end.
      expect(ratio, lessThan(20), reason: '64 bars took ${ratio.toStringAsFixed(1)}x as long as 8');
    });
  });

  test('long tracks are written on a background isolate, and a sound that cannot play returns zero', () async {
    final dir = Directory.systemTemp.createTempSync('guitaro_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (call) async => dir.path);
    final logs = <String>[];
    final saved = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => logs.add(message ?? '');
    addTearDown(() => debugPrint = saved);

    final bars = [for (final id in ['G', 'C', 'D', 'Em']) library.byId(id)];
    // No audio plugin in tests, so playing fails after the file is written; that must not throw.
    final length = await SoundPlayer()
        .playChords(key: 'test', bars: bars, strum: folk, bpm: 90);
    expect(length, Duration.zero);
    expect(logs.single, contains('failed to play'));
    // The file, written block by block, is exactly the whole track encoded at once.
    final written = dir.listSync().whereType<File>().single.readAsBytesSync();
    final whole = synth.toWav(SoundPlayer.renderBars(synth, bars, strum: folk, bpm: 90).renderAll());
    expect(written.length, whole.length);
    expect(written, orderedEquals(whole));
  });
}
