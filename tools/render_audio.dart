// Renders a guitar track for a lesson video with the app's own synth.
//
//   dart run tools/render_audio.dart events.json out.wav
//
// events.json: {"seconds": 42.0, "events": [
//   {"t": 1.5, "kind": "strum", "notes": [40, 47, 52], "down": true, "gain": 1.0},
//   {"t": 3.0, "kind": "note", "midi": 64, "gain": 1.0},
//   {"t": 4.0, "kind": "click", "accent": true}]}
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fretwise/audio/synth.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tools/render_audio.dart events.json out.wav');
    exit(64);
  }
  final spec = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final synth = GuitarSynth();
  final sr = synth.sampleRate;
  final out = Float32List(((spec['seconds'] as num) * sr).ceil());
  var seed = 1;
  for (final e in (spec['events'] as List).cast<Map<String, dynamic>>()) {
    final at = ((e['t'] as num) * sr).round();
    final gain = (e['gain'] as num?)?.toDouble() ?? 1.0;
    switch (e['kind']) {
      case 'strum':
        synth.addStrum(out, at, List<int>.from(e['notes'] as List),
            down: e['down'] as bool? ?? true, gain: 0.32 * gain, seed: seed++);
      case 'note':
        synth.addNote(out, at, e['midi'] as int, gain: 0.5 * gain, seed: seed++);
      case 'click':
        synth.addClick(out, at, accent: e['accent'] as bool? ?? false);
    }
  }
  // Gentle limiter so dense strumming never clips.
  for (var i = 0; i < out.length; i++) {
    final x = out[i];
    out[i] = x.abs() < 0.7 ? x : (x.sign * (0.7 + 0.3 * (1 - 1 / (1 + (x.abs() - 0.7) * 3))));
  }
  File(args[1]).writeAsBytesSync(synth.toWav(out));
}
