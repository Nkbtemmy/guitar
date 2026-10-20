import 'dart:math' as math;
import 'dart:typed_data';

import '../music/notes.dart';

/// Plucked-string synthesis (Karplus-Strong with fractional-delay tuning) and WAV encoding.
/// Used for "hear it" buttons, tuner reference tones, metronome clicks, and as test signals.
class GuitarSynth {
  GuitarSynth({this.sampleRate = 44100});

  final int sampleRate;

  Float32List pluck(double freq, {double seconds = 2.0, int seed = 1, double decay = 0.996, double brightness = 0.5}) {
    final out = Float32List((seconds * sampleRate).round());
    _addPluck(out, 0, freq, seed: seed, decay: decay, brightness: brightness);
    _normalize(out, 0.8);
    return out;
  }

  /// Strums [midiNotes] (low to high) with [spreadMs] between strings. Up-strums play high to low.
  Float32List strum(List<int> midiNotes, {double seconds = 2.5, bool down = true, double spreadMs = 18, int seed = 7}) {
    final out = Float32List((seconds * sampleRate).round());
    addStrum(out, 0, midiNotes, down: down, spreadMs: spreadMs, seed: seed);
    _normalize(out, 0.8);
    return out;
  }

  /// Mixes a strum into [out] starting at [startSample]. Returns [out] for chaining.
  Float32List addStrum(Float32List out, int startSample, List<int> midiNotes,
      {bool down = true, double spreadMs = 18, int seed = 7, double gain = 1.0}) {
    final order = down ? midiNotes : midiNotes.reversed.toList();
    final spread = (spreadMs / 1000 * sampleRate).round();
    for (var i = 0; i < order.length; i++) {
      _addPluck(out, startSample + i * spread, midiToFreq(order[i]),
          seed: seed * 31 + i, gain: gain * (down ? 1.0 : 0.7), brightness: down ? 0.35 : 0.5);
    }
    return out;
  }

  /// Plays the notes one at a time, [gapMs] apart, letting each ring.
  Float32List arpeggio(List<int> midiNotes, {double gapMs = 350, double tailSeconds = 1.5}) {
    final gap = (gapMs / 1000 * sampleRate).round();
    final out = Float32List(gap * midiNotes.length + (tailSeconds * sampleRate).round());
    for (var i = 0; i < midiNotes.length; i++) {
      _addPluck(out, i * gap, midiToFreq(midiNotes[i]), seed: 11 + i);
    }
    _normalize(out, 0.8);
    return out;
  }

  /// A count-in plus [bars] of metronome clicks; beat 1 of each bar is accented.
  Float32List clickTrack({required int bpm, required int beatsPerBar, required int bars}) {
    final beat = 60 / bpm * sampleRate;
    final total = beatsPerBar * bars;
    final out = Float32List((beat * total + sampleRate * 0.2).round());
    for (var b = 0; b < total; b++) {
      _addClick(out, (b * beat).round(), accent: b % beatsPerBar == 0);
    }
    return out;
  }

  /// Clicks sit above the analyzer's 2.1 kHz band and carry no low end, so they never read as
  /// notes, chords or strums while the mic listens during play-alongs.
  /// The onset detector notches out exactly these, so keep them in sync.
  static const clickFrequencies = [2400.0, 3000.0];

  void _addClick(Float32List out, int start, {required bool accent}) {
    final freq = accent ? clickFrequencies[1] : clickFrequencies[0];
    final len = (0.04 * sampleRate).round();
    final attack = 0.003 * sampleRate;
    for (var i = 0; i < len && start + i < out.length; i++) {
      // Smooth attack keeps the click narrowband (no broadband tick for the onset detector).
      final rise = i < attack ? 0.5 - 0.5 * math.cos(math.pi * i / attack) : 1.0;
      final env = rise * math.exp(-i / (0.008 * sampleRate));
      out[start + i] += (accent ? 0.9 : 0.6) * env * math.sin(2 * math.pi * freq * i / sampleRate);
    }
  }

  void _addPluck(Float32List out, int start, double freq,
      {int seed = 1, double decay = 0.996, double brightness = 0.5, double gain = 1.0}) {
    if (start >= out.length) return;
    // Loop delay = n - 0.5 (averaging the samples n and n-1 steps back) + allpass delay d.
    final period = sampleRate / freq;
    var n = (period + 0.5).floor();
    var d = period + 0.5 - n;
    if (d < 0.1) {
      n -= 1;
      d += 1;
    }
    final c = (1 - d) / (1 + d);
    final rnd = math.Random(seed);
    final buf = Float64List(n);
    // Noise burst, low-passed by [brightness] for a softer attack.
    var prev = 0.0;
    for (var i = 0; i < n; i++) {
      final white = rnd.nextDouble() * 2 - 1;
      prev = brightness * white + (1 - brightness) * prev;
      buf[i] = prev;
    }
    final mean = buf.fold<double>(0, (a, b) => a + b) / n;
    for (var i = 0; i < n; i++) {
      buf[i] -= mean;
    }
    var idx = 0;
    var apIn = 0.0, apOut = 0.0;
    for (var i = start; i < out.length; i++) {
      final cur = buf[idx];
      final next = buf[(idx + 1) % n];
      final avg = decay * 0.5 * (cur + next);
      final ap = c * avg + apIn - c * apOut;
      apIn = avg;
      apOut = ap;
      buf[idx] = ap;
      out[i] += gain * cur;
      idx = (idx + 1) % n;
    }
  }

  static void _normalize(Float32List data, double peak) {
    var max = 0.0;
    for (final v in data) {
      if (v.abs() > max) max = v.abs();
    }
    if (max == 0) return;
    final k = peak / max;
    for (var i = 0; i < data.length; i++) {
      data[i] *= k;
    }
  }

  static void normalize(Float32List data, [double peak = 0.8]) => _normalize(data, peak);

  /// 16-bit mono PCM WAV.
  Uint8List toWav(Float32List samples) {
    final dataLen = samples.length * 2;
    final bytes = ByteData(44 + dataLen);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        bytes.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    bytes.setUint32(4, 36 + dataLen, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    bytes.setUint32(40, dataLen, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      bytes.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
    }
    return bytes.buffer.asUint8List();
  }
}
