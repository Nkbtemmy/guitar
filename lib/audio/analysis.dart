import 'dart:math' as math;
import 'dart:typed_data';

import '../music/notes.dart';
import 'synth.dart';

/// Radix-2 FFT: in place on complex data, or the magnitude spectrum of a real signal.
class Fft {
  Fft(this.size)
      : assert(size > 0 && (size & (size - 1)) == 0, 'size must be a power of two'),
        _cos = Float64List(size ~/ 2),
        _sin = Float64List(size ~/ 2),
        _rev = Int32List(size),
        _re = Float64List(size),
        _im = Float64List(size) {
    for (var i = 0; i < size ~/ 2; i++) {
      _cos[i] = math.cos(-2 * math.pi * i / size);
      _sin[i] = math.sin(-2 * math.pi * i / size);
    }
    final bits = (math.log(size) / math.ln2).round();
    for (var i = 0; i < size; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if (i & (1 << b) != 0) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
  }

  final int size;
  final Float64List _cos, _sin, _re, _im;
  final Int32List _rev;

  /// Magnitudes for bins 0..size/2.
  Float64List magnitudes(Float64List input) {
    _re.setRange(0, size, input);
    _im.fillRange(0, size, 0);
    transform(_re, _im);
    final out = Float64List(size ~/ 2 + 1);
    for (var i = 0; i < out.length; i++) {
      out[i] = math.sqrt(_re[i] * _re[i] + _im[i] * _im[i]);
    }
    return out;
  }

  /// Transforms [re] + i·[im] ([size] values each) in place. The [inverse] is scaled by 1/size,
  /// so a round trip gives the input back.
  void transform(Float64List re, Float64List im, {bool inverse = false}) {
    for (var i = 0; i < size; i++) {
      final j = _rev[i];
      if (j <= i) continue;
      final r = re[i], m = im[i];
      re[i] = re[j];
      im[i] = im[j];
      re[j] = r;
      im[j] = m;
    }
    final sign = inverse ? -1.0 : 1.0;
    for (var len = 2; len <= size; len <<= 1) {
      final half = len >> 1;
      final step = size ~/ len;
      for (var start = 0; start < size; start += len) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step], wi = sign * _sin[k * step];
          final a = start + k, b = a + half;
          final tr = re[b] * wr - im[b] * wi;
          final ti = re[b] * wi + im[b] * wr;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
    if (inverse) {
      for (var i = 0; i < size; i++) {
        re[i] /= size;
        im[i] /= size;
      }
    }
  }
}

class PitchResult {
  const PitchResult(this.frequency, this.clarity);

  final double frequency;

  /// 0..1, how periodic the signal is. Single plucked notes score above ~0.9.
  final double clarity;

  double get midi => freqToMidi(frequency);
}

/// YIN fundamental-frequency estimator (de Cheveigné & Kawahara, 2002).
class YinPitchDetector {
  YinPitchDetector({required this.sampleRate, this.minFreq = 70, this.maxFreq = 1400, this.threshold = 0.15});

  final int sampleRate;
  final double minFreq, maxFreq, threshold;

  PitchResult? detect(Float64List x, [int start = 0, int? end]) {
    end ??= x.length;
    final tauMax = (sampleRate / minFreq).ceil();
    final tauMin = math.max(2, (sampleRate / maxFreq).floor());
    final w = end - start - tauMax;
    if (w < tauMax ~/ 2) return null;

    final d = _difference(x, start, w, tauMax);
    // Cumulative mean normalized difference.
    final cmnd = Float64List(tauMax + 2)..[0] = 1;
    var running = 0.0;
    for (var tau = 1; tau < cmnd.length; tau++) {
      running += d[tau];
      cmnd[tau] = running == 0 ? 1 : d[tau] * tau / running;
    }

    var tau = -1;
    for (var t = tauMin; t <= tauMax; t++) {
      if (cmnd[t] < threshold) {
        while (t + 1 <= tauMax && cmnd[t + 1] < cmnd[t]) {
          t++;
        }
        tau = t;
        break;
      }
    }
    if (tau < 0) {
      var best = tauMin;
      for (var t = tauMin; t <= tauMax; t++) {
        if (cmnd[t] < cmnd[best]) best = t;
      }
      if (cmnd[best] > 0.35) return null;
      tau = best;
    }

    var refined = tau.toDouble();
    if (tau > 1 && tau < tauMax + 1) {
      final a = cmnd[tau - 1], b = cmnd[tau], c = cmnd[tau + 1];
      final denom = a - 2 * b + c;
      if (denom.abs() > 1e-12) refined = tau + 0.5 * (a - c) / denom;
    }
    return PitchResult(sampleRate / refined, (1 - cmnd[tau]).clamp(0.0, 1.0));
  }

  Fft? _fft;
  Float64List _ar = Float64List(0), _ai = Float64List(0), _br = Float64List(0), _bi = Float64List(0);

  /// The difference function d(τ) = Σ (x[j] − x[j+τ])² over [w] samples, for τ = 1..[tauMax].
  /// Summed directly that's w × tauMax multiply-adds (~900k a frame, most of the analysis time,
  /// on the UI thread). Expanded, it's energy(0) + energy(τ) − 2·r(τ): the energies come from a
  /// running sum, and the correlation r from three FFTs.
  Float64List _difference(Float64List x, int start, int w, int tauMax) {
    final n = w + tauMax;
    var size = 1;
    while (size < n) {
      size <<= 1;
    }
    // Zero-padded to [size] >= n, the circular correlation never wraps: j + τ <= n - 1.
    final fft = _fft?.size == size ? _fft! : (_fft = Fft(size));
    if (_ar.length != size) {
      _ar = Float64List(size);
      _ai = Float64List(size);
      _br = Float64List(size);
      _bi = Float64List(size);
    }
    final ar = _ar, ai = _ai, br = _br, bi = _bi;
    ar.fillRange(0, size, 0);
    ai.fillRange(0, size, 0);
    br.fillRange(0, size, 0);
    bi.fillRange(0, size, 0);
    ar.setRange(0, w, x, start);
    br.setRange(0, n, x, start);
    fft.transform(ar, ai);
    fft.transform(br, bi);
    // conj(A)·B, then back: br[τ] = r(τ) = Σ x[j]·x[j+τ].
    for (var k = 0; k < size; k++) {
      final re = ar[k] * br[k] + ai[k] * bi[k];
      final im = ar[k] * bi[k] - ai[k] * br[k];
      br[k] = re;
      bi[k] = im;
    }
    fft.transform(br, bi, inverse: true);
    // energy(τ) = Σ x[j]² for j in τ..τ+w-1, from a running sum.
    final energy = ai; // free again: reuse it for the running sum
    var sum = 0.0;
    for (var j = 0; j < n; j++) {
      energy[j] = sum;
      sum += x[start + j] * x[start + j];
    }
    double before(int j) => j < n ? energy[j] : sum;
    final e0 = before(w);
    final d = Float64List(tauMax + 2);
    for (var tau = 1; tau <= tauMax; tau++) {
      // Rounding can leave a hair below zero where the true value is ~0 (a perfect repeat).
      d[tau] = math.max(0.0, e0 + before(tau + w) - before(tau) - 2 * br[tau]);
    }
    return d;
  }
}

class SpectralPeak {
  const SpectralPeak(this.frequency, this.magnitude);

  final double frequency;
  final double magnitude;
}

/// Finds the strongest spectral peaks (sorted loudest first) between [minFreq] and [maxFreq].
class SpectrumAnalyzer {
  SpectrumAnalyzer({required this.sampleRate, this.size = 8192, this.minFreq = 60, this.maxFreq = 2100})
      : _fft = Fft(size),
        _window = Float64List(size),
        _frame = Float64List(size) {
    for (var i = 0; i < size; i++) {
      _window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (size - 1));
    }
  }

  final int sampleRate, size;
  final double minFreq, maxFreq;
  final Fft _fft;
  final Float64List _window, _frame;

  /// [minAmplitude] is an absolute floor (sine amplitude) for the loudest in-band peak, so sound
  /// outside the band, like metronome clicks, doesn't count as playing.
  List<SpectralPeak> peaks(Float64List samples,
      {int start = 0, int maxPeaks = 48, double relThreshold = 0.03, double minAmplitude = 0}) {
    for (var i = 0; i < size; i++) {
      _frame[i] = samples[start + i] * _window[i];
    }
    final mag = _fft.magnitudes(_frame);
    final binHz = sampleRate / size;
    final lo = math.max(2, (minFreq / binHz).floor());
    final hi = math.min(mag.length - 3, (maxFreq / binHz).ceil());
    var maxMag = 0.0;
    for (var k = lo; k <= hi; k++) {
      if (mag[k] > maxMag) maxMag = mag[k];
    }
    // A Hann-windowed sine of amplitude A peaks at A * size / 4.
    if (maxMag == 0 || 4 * maxMag / size < minAmplitude) return const [];
    final floor = maxMag * relThreshold;
    final found = <SpectralPeak>[];
    for (var k = lo; k <= hi; k++) {
      final m = mag[k];
      if (m < floor || m < mag[k - 1] || m < mag[k + 1] || m < mag[k - 2] || m < mag[k + 2]) continue;
      // Parabolic interpolation on log magnitude.
      final a = math.log(mag[k - 1] + 1e-12), b = math.log(m + 1e-12), c = math.log(mag[k + 1] + 1e-12);
      final denom = a - 2 * b + c;
      final p = denom.abs() < 1e-12 ? 0.0 : 0.5 * (a - c) / denom;
      found.add(SpectralPeak((k + p) * binHz, m));
    }
    found.sort((x, y) => y.magnitude.compareTo(x.magnitude));
    return found.length > maxPeaks ? found.sublist(0, maxPeaks) : found;
  }
}

/// Biquad notch (RBJ cookbook) used to strip the metronome tones before onset detection.
class _Notch {
  _Notch(double freq, int sampleRate, {double q = 1.5}) {
    final w0 = 2 * math.pi * freq / sampleRate;
    final alpha = math.sin(w0) / (2 * q);
    final a0 = 1 + alpha;
    _b0 = 1 / a0;
    _b1 = -2 * math.cos(w0) / a0;
    _b2 = 1 / a0;
    _a1 = -2 * math.cos(w0) / a0;
    _a2 = (1 - alpha) / a0;
  }

  late final double _b0, _b1, _b2, _a1, _a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  double process(double x) {
    final y = _b0 * x + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}

/// Detects pick attacks from jumps in high-frequency energy (first difference of the signal).
/// The metronome's two click tones are notched out first (two cascaded notches each, ~40 dB) so
/// clicks don't read as strums.
class OnsetDetector {
  OnsetDetector({
    required this.sampleRate,
    this.hop = 512,
    this.ratio = 2.2,
    this.gate = 0.006,
    this.refractory = 0.08,
    List<double> notchFrequencies = GuitarSynth.clickFrequencies,
  }) : _notches = [for (final f in notchFrequencies) ...[_Notch(f, sampleRate), _Notch(f, sampleRate)]];

  final int sampleRate, hop;
  final double ratio, refractory;
  double gate;

  final List<_Notch> _notches;
  final List<double> _history = [];
  final Float64List _hopBuf = Float64List(4096);
  int _fill = 0;
  int _processed = 0;
  double _prevSample = 0;
  double _lastOnset = -1;
  double _prevEnergy = 0;

  /// Feeds samples; returns onset times in seconds since the first sample.
  List<double> process(Float32List samples, [int start = 0, int? end]) {
    end ??= samples.length;
    final onsets = <double>[];
    for (var i = start; i < end; i++) {
      var s = samples[i].toDouble();
      for (final n in _notches) {
        s = n.process(s);
      }
      _hopBuf[_fill++] = s;
      if (_fill < hop) continue;
      var hf = 0.0, raw = 0.0;
      for (var j = 0; j < hop; j++) {
        final x = _hopBuf[j];
        final diff = x - (j == 0 ? _prevSample : _hopBuf[j - 1]);
        hf += diff * diff;
        raw += x * x;
      }
      _prevSample = _hopBuf[hop - 1];
      final rms = math.sqrt(raw / hop);
      final t = _processed / sampleRate;
      final base = _history.isEmpty ? 0.0 : _history.reduce(math.max);
      if (rms > gate && hf > ratio * base + 1e-9 && hf > _prevEnergy && t - _lastOnset > refractory) {
        onsets.add(t);
        _lastOnset = t;
      }
      _prevEnergy = hf;
      _history.add(hf);
      if (_history.length > 3) _history.removeAt(0);
      _processed += hop;
      _fill = 0;
    }
    return onsets;
  }
}

class AnalysisFrame {
  const AnalysisFrame({
    required this.time,
    required this.rms,
    this.pitch,
    this.peaks = const [],
    this.onsets = const [],
  });

  /// Seconds since the stream started, at the end of this frame.
  final double time;
  final double rms;
  final PitchResult? pitch;
  final List<SpectralPeak> peaks;

  /// Onsets (seconds since start) detected since the previous frame.
  final List<double> onsets;

  bool get hasSound => peaks.isNotEmpty;
}

/// Turns a raw sample stream into [AnalysisFrame]s every [hopSize] samples.
class AudioAnalyzer {
  AudioAnalyzer({
    this.sampleRate = 44100,
    this.hopSize = 2048,
    this.fftSize = 8192,
    this.pitchSize = 2048,
    double gate = 0.01,
  })  : _gate = gate,
        _buf = Float64List(fftSize),
        _yin = YinPitchDetector(sampleRate: sampleRate),
        _spectrum = SpectrumAnalyzer(sampleRate: sampleRate, size: fftSize),
        _onsets = OnsetDetector(sampleRate: sampleRate, gate: gate * 0.6);

  final int sampleRate, hopSize, fftSize, pitchSize;
  final Float64List _buf;
  final YinPitchDetector _yin;
  final SpectrumAnalyzer _spectrum;
  final OnsetDetector _onsets;
  double _gate;
  int _total = 0;
  int _sinceFrame = 0;
  final List<double> _pendingOnsets = [];

  double get gate => _gate;
  set gate(double v) {
    _gate = v;
    _onsets.gate = v * 0.6;
  }

  double get hopSeconds => hopSize / sampleRate;

  /// Feeds samples and returns the frames that became due.
  List<AnalysisFrame> add(Float32List samples) {
    final frames = <AnalysisFrame>[];
    var offset = 0;
    while (offset < samples.length) {
      final n = math.min(hopSize - _sinceFrame, samples.length - offset);
      _pendingOnsets.addAll(_onsets.process(samples, offset, offset + n));
      if (n >= fftSize) {
        for (var i = 0; i < fftSize; i++) {
          _buf[i] = samples[offset + n - fftSize + i];
        }
      } else {
        _buf.setRange(0, fftSize - n, _buf, n);
        for (var i = 0; i < n; i++) {
          _buf[fftSize - n + i] = samples[offset + i];
        }
      }
      offset += n;
      _total += n;
      _sinceFrame += n;
      if (_sinceFrame >= hopSize) {
        _sinceFrame = 0;
        frames.add(_analyze());
      }
    }
    return frames;
  }

  AnalysisFrame _analyze() {
    var sum = 0.0;
    for (var i = fftSize - pitchSize; i < fftSize; i++) {
      sum += _buf[i] * _buf[i];
    }
    final rms = math.sqrt(sum / pitchSize);
    final onsets = List<double>.of(_pendingOnsets);
    _pendingOnsets.clear();
    final time = _total / sampleRate;
    if (rms < _gate) return AnalysisFrame(time: time, rms: rms, onsets: onsets);
    final peaks = _spectrum.peaks(_buf, minAmplitude: _gate * 0.5);
    if (peaks.isEmpty) return AnalysisFrame(time: time, rms: rms, onsets: onsets);
    final pitch = _yin.detect(_buf, fftSize - pitchSize, fftSize);
    return AnalysisFrame(
      time: time,
      rms: rms,
      pitch: pitch,
      peaks: peaks,
      onsets: onsets,
    );
  }
}

/// Turns little-endian 16-bit PCM bytes into -1..1 samples. A chunk may end mid-sample; the
/// odd byte is kept for the next chunk.
class Pcm16Decoder {
  int _leftoverByte = -1;

  void reset() => _leftoverByte = -1;

  Float32List decode(Uint8List bytes) {
    var start = 0;
    final samples = Float32List((bytes.length + (_leftoverByte >= 0 ? 1 : 0)) ~/ 2);
    var n = 0;
    if (_leftoverByte >= 0 && bytes.isNotEmpty) {
      samples[n++] = ((bytes[0] << 8 | _leftoverByte).toSigned(16)) / 32768;
      start = 1;
      _leftoverByte = -1;
    }
    for (var i = start; i + 1 < bytes.length; i += 2) {
      samples[n++] = ((bytes[i + 1] << 8 | bytes[i]).toSigned(16)) / 32768;
    }
    if ((bytes.length - start).isOdd) _leftoverByte = bytes.last;
    return Float32List.sublistView(samples, 0, n);
  }
}
