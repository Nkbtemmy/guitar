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

  /// Samples between one string and the next in a strum.
  int strumSpread([double spreadMs = 18]) => (spreadMs / 1000 * sampleRate).round();

  /// Mixes a strum into [out] starting at [startSample]. Returns [out] for chaining.
  /// [lengths] (one per note, low to high; null lets it ring) damps notes as [addNote] does.
  Float32List addStrum(Float32List out, int startSample, List<int> midiNotes,
      {bool down = true, double spreadMs = 18, int seed = 7, double gain = 1.0, List<int?>? lengths}) {
    for (final p in _strum(startSample, midiNotes,
        down: down, spreadMs: spreadMs, seed: seed, gain: gain, lengths: lengths)) {
      _mixPluck(out, p);
    }
    return out;
  }

  /// The plucks of a strum, one per string in the order they're struck.
  List<_PluckSpec> _strum(int startSample, List<int> midiNotes,
      {required bool down, required double spreadMs, required int seed, required double gain, List<int?>? lengths}) {
    final order = down ? midiNotes : midiNotes.reversed.toList();
    final spread = strumSpread(spreadMs);
    return [
      for (var i = 0; i < order.length; i++)
        (
          start: startSample + i * spread,
          freq: midiToFreq(order[i]),
          seed: seed * 31 + i,
          decay: 0.996,
          brightness: down ? 0.35 : 0.5,
          gain: gain * (down ? 1.0 : 0.7),
          length: lengths?[down ? i : order.length - 1 - i],
        ),
    ];
  }

  /// Mixes one plucked note into [out] at [startSample]. With [lengthSamples] the note is
  /// damped after that long (as when the same string is picked again), with a short fade.
  void addNote(Float32List out, int startSample, int midi, {double gain = 1.0, int seed = 1, int? lengthSamples}) =>
      _addPluck(out, startSample, midiToFreq(midi), seed: seed, gain: gain, length: lengthSamples);

  /// Mixes one metronome click into [out] at [startSample].
  void addClick(Float32List out, int startSample, {bool accent = false}) => _addClick(out, startSample, accent: accent);

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

  int get _clickLength => (0.04 * sampleRate).round();

  /// Mixes the part of a click at [start] that falls in [out], which holds samples [from]
  /// onwards of a track [total] samples long.
  void _addClick(Float32List out, int start, {required bool accent, int from = 0, int? total}) {
    final freq = accent ? clickFrequencies[1] : clickFrequencies[0];
    final len = _clickLength;
    final attack = 0.003 * sampleRate;
    final until = math.min(len, math.min(total ?? out.length, from + out.length) - start);
    for (var i = math.max(0, from - start); i < until; i++) {
      // Smooth attack keeps the click narrowband (no broadband tick for the onset detector).
      final rise = i < attack ? 0.5 - 0.5 * math.cos(math.pi * i / attack) : 1.0;
      final env = rise * math.exp(-i / (0.008 * sampleRate));
      out[start + i - from] += (accent ? 0.9 : 0.6) * env * math.sin(2 * math.pi * freq * i / sampleRate);
    }
  }

  void _addPluck(Float32List out, int start, double freq,
          {int seed = 1, double decay = 0.996, double brightness = 0.5, double gain = 1.0, int? length}) =>
      _mixPluck(out, (
        start: start,
        freq: freq,
        seed: seed,
        decay: decay,
        brightness: brightness,
        gain: gain,
        length: length,
      ));

  void _mixPluck(Float32List out, _PluckSpec p) {
    if (p.start < out.length) _Pluck(this, p, out.length).mix(out, 0);
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
    final wav = Uint8List(44 + samples.length * 2);
    wav.setAll(0, wavHeader(samples.length));
    _pcm16(samples, ByteData.sublistView(wav, 44));
    return wav;
  }

  /// The 44-byte header of a 16-bit mono WAV file holding [samples] samples.
  Uint8List wavHeader(int samples) {
    final dataLen = samples * 2;
    final bytes = ByteData(44);
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
    return bytes.buffer.asUint8List();
  }

  /// [samples] as little-endian 16-bit PCM, the body of a WAV file.
  Uint8List pcm16(Float32List samples) {
    final bytes = Uint8List(samples.length * 2);
    _pcm16(samples, ByteData.sublistView(bytes));
    return bytes;
  }

  static void _pcm16(Float32List samples, ByteData into) {
    for (var i = 0; i < samples.length; i++) {
      into.setInt16(i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
    }
  }
}

typedef _PluckSpec = ({int start, double freq, int seed, double decay, double brightness, double gain, int? length});
typedef _ClickSpec = ({int start, bool accent});

/// One plucked string: Karplus-Strong with fractional-delay tuning, synthesized a block at a
/// time (each [mix] carries on where the last one stopped).
class _Pluck {
  factory _Pluck(GuitarSynth synth, _PluckSpec p, int total) {
    final end = p.length == null ? total : math.min(total, p.start + p.length!);
    final fade = (0.03 * synth.sampleRate).round();
    // Loop delay = n - 0.5 (averaging the samples n and n-1 steps back) + allpass delay d.
    final period = synth.sampleRate / p.freq;
    var n = (period + 0.5).floor();
    var d = period + 0.5 - n;
    if (d < 0.1) {
      n -= 1;
      d += 1;
    }
    final rnd = math.Random(p.seed);
    final buf = Float64List(n);
    // Noise burst, low-passed by [brightness] for a softer attack.
    var prev = 0.0;
    for (var i = 0; i < n; i++) {
      final white = rnd.nextDouble() * 2 - 1;
      prev = p.brightness * white + (1 - p.brightness) * prev;
      buf[i] = prev;
    }
    final mean = buf.fold<double>(0, (a, b) => a + b) / n;
    for (var i = 0; i < n; i++) {
      buf[i] -= mean;
    }
    // A damped note fades out over the samples after fadeFrom.
    return _Pluck._(buf, (1 - d) / (1 + d), p.decay, p.gain, p.start, end, fade, p.length == null ? end : end - fade);
  }

  _Pluck._(this._buf, this._c, this._decay, this._gain, this._pos, this._end, this._fade, this._fadeFrom);

  final Float64List _buf;
  final double _c, _decay, _gain;
  final int _end, _fade, _fadeFrom;
  int _pos, _idx = 0;
  double _apIn = 0, _apOut = 0;

  bool get done => _pos >= _end;

  /// Mixes this note's samples that fall in [out], which holds samples [from] onwards.
  void mix(Float32List out, int from) {
    assert(_pos >= from, 'blocks must be mixed in order');
    final buf = _buf, n = _buf.length;
    final c = _c, decay = _decay, gain = _gain, end = _end, fade = _fade, fadeFrom = _fadeFrom;
    final stop = math.min(end, from + out.length);
    var idx = _idx;
    var apIn = _apIn, apOut = _apOut;
    var i = _pos;
    for (; i < stop; i++) {
      // Wrap with a compare, not `%`: the integer divide was ~40% of this loop's time.
      final nextIdx = idx + 1 == n ? 0 : idx + 1;
      final cur = buf[idx];
      final avg = decay * 0.5 * (cur + buf[nextIdx]);
      final ap = c * avg + apIn - c * apOut;
      apIn = avg;
      apOut = ap;
      buf[idx] = ap;
      out[i - from] += gain * cur * (i > fadeFrom ? (end - i) / fade : 1.0);
      idx = nextIdx;
    }
    if (i > _pos) _pos = i;
    _idx = idx;
    _apIn = apIn;
    _apOut = apOut;
  }
}

/// A long arrangement of plucks and clicks (a song, a tab) that is synthesized a block at a
/// time, so memory stays small however long it is: a whole song at a slow tempo runs to tens of
/// millions of samples. The calls mirror [GuitarSynth.addStrum], [GuitarSynth.addNote],
/// [GuitarSynth.addClick] and [GuitarSynth.normalize] on a [Float32List], and the result is the
/// same, sample for sample.
class SynthTrack {
  SynthTrack(this.synth, this.length);

  final GuitarSynth synth;

  /// In samples.
  final int length;

  static const _blockSize = 1 << 14;

  // Plucks and clicks in the order they were added; those before [_normalizeAt] get normalized.
  final _events = <Object>[];
  int? _normalizeAt;
  double _peak = 0.8;

  void addStrum(int startSample, List<int> midiNotes,
          {bool down = true, double spreadMs = 18, int seed = 7, double gain = 1.0, List<int?>? lengths}) =>
      _events.addAll(
          synth._strum(startSample, midiNotes, down: down, spreadMs: spreadMs, seed: seed, gain: gain, lengths: lengths));

  void addNote(int startSample, int midi, {double gain = 1.0, int seed = 1, int? lengthSamples}) => _events.add((
        start: startSample,
        freq: midiToFreq(midi),
        seed: seed,
        decay: 0.996,
        brightness: 0.5,
        gain: gain,
        length: lengthSamples,
      ));

  void addClick(int startSample, {bool accent = false}) => _events.add((start: startSample, accent: accent));

  /// Scales what has been added so far to peak at [peak]; what's added afterwards goes on top.
  void normalize([double peak = 0.8]) {
    assert(_normalizeAt == null, 'normalize once');
    _normalizeAt = _events.length;
    _peak = peak;
  }

  /// Synthesizes the track in order, handing each block of samples to [emit]. The block is
  /// reused, so [emit] must be done with it when it returns.
  void render(void Function(Float32List block) emit) {
    final split = _normalizeAt ?? 0;
    final block = Float32List(_blockSize);
    var k = 1.0;
    if (_normalizeAt != null) {
      // Normalizing needs the peak first: one pass to find it, a second to write.
      final peakPass = _Mixer(synth, _events.sublist(0, split), length);
      var max = 0.0;
      for (var from = 0; from < length; from += _blockSize) {
        final b = _block(block, from);
        peakPass.mix(b, from);
        for (final v in b) {
          if (v.abs() > max) max = v.abs();
        }
      }
      if (max != 0) k = _peak / max;
    }
    final scaled = _Mixer(synth, _events.sublist(0, split), length);
    final onTop = _Mixer(synth, _events.sublist(split), length);
    for (var from = 0; from < length; from += _blockSize) {
      final b = _block(block, from);
      scaled.mix(b, from);
      if (k != 1.0) {
        for (var i = 0; i < b.length; i++) {
          b[i] *= k;
        }
      }
      onTop.mix(b, from);
      emit(b);
    }
  }

  /// The block for samples [from] onwards, cleared.
  Float32List _block(Float32List block, int from) {
    final n = math.min(_blockSize, length - from);
    block.fillRange(0, n, 0);
    return n == _blockSize ? block : Float32List.sublistView(block, 0, n);
  }

  /// The whole track at once (for short ones, and tests).
  Float32List renderAll() {
    final out = Float32List(length);
    var at = 0;
    render((block) {
      out.setAll(at, block);
      at += block.length;
    });
    return out;
  }
}

/// Mixes a list of plucks and clicks block by block, keeping each sounding note's state.
class _Mixer {
  _Mixer(this.synth, this.events, this.total)
      : _voices = List.filled(events.length, null),
        _done = List.filled(events.length, false);

  final GuitarSynth synth;
  final List<Object> events;
  final int total;
  final List<_Pluck?> _voices;
  final List<bool> _done;

  /// Adds everything that sounds in [out] (samples [from] onwards), in the order it was added,
  /// so each sample sums exactly as it would in one long buffer.
  void mix(Float32List out, int from) {
    final to = from + out.length;
    for (var i = 0; i < events.length; i++) {
      if (_done[i]) continue;
      final e = events[i];
      if (e is _PluckSpec) {
        if (e.start >= to) continue;
        final voice = _voices[i] ??= _Pluck(synth, e, total);
        voice.mix(out, from);
        if (voice.done) {
          _voices[i] = null;
          _done[i] = true;
        }
      } else if (e is _ClickSpec) {
        if (e.start >= to) continue;
        synth._addClick(out, e.start, accent: e.accent, from: from, total: total);
        if (e.start + synth._clickLength <= to) _done[i] = true;
      }
    }
  }
}
