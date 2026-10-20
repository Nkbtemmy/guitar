import 'dart:math' as math;

import '../music/chord.dart';
import '../music/notes.dart';
import 'analysis.dart';

class ChordScore {
  const ChordScore(this.chord, this.score);

  final Chord chord;
  final double score;
}

class ChordVerdict {
  const ChordVerdict({required this.matches, required this.score, required this.best});

  final bool matches;

  /// How well what was heard fits the expected voicing, 0..1.
  final double score;

  /// The library chord that fits best (may be a same-note voicing of the expected one).
  final Chord best;
}

double _cents(double freq) => 1200 * math.log(freq) / math.ln2;

class _Voicing {
  _Voicing(List<int> midiNotes, double maxFreq) {
    for (final note in midiNotes) {
      final f0 = midiToFreq(note);
      for (var h = 1; h <= 16 && f0 * h <= maxFreq; h++) {
        partials.add(_cents(f0 * h));
        if (h <= 3) {
          keyPartials.add(_cents(f0 * h));
          keyWeights.add(1 / math.sqrt(h));
        }
      }
    }
    totalKeyWeight = keyWeights.fold(0, (a, b) => a + b);
  }

  final partials = <double>[];
  final keyPartials = <double>[];
  final keyWeights = <double>[];
  late final double totalKeyWeight;
}

/// Scores spectral peaks against each chord's exact voicing (string by string, octave included):
/// precision = share of heard energy the voicing explains, recall = share of the voicing's strong
/// partials that were heard. Score is their geometric mean.
class ChordMatcher {
  ChordMatcher(this.chords, {this.toleranceCents = 35, this.maxFreq = 2100})
      : _voicings = {for (final c in chords) c.id: _Voicing(c.midiNotes, maxFreq)};

  final List<Chord> chords;
  final double toleranceCents, maxFreq;
  final Map<String, _Voicing> _voicings;

  double score(List<SpectralPeak> peaks, Chord chord) {
    if (peaks.isEmpty) return 0;
    final v = _voicings[chord.id] ?? _Voicing(chord.midiNotes, maxFreq);
    final loudest = peaks.first.magnitude;
    final peakCents = [for (final p in peaks) _cents(p.frequency)];

    var total = 0.0, explained = 0.0;
    for (var i = 0; i < peaks.length; i++) {
      final w = math.sqrt(peaks[i].magnitude / loudest);
      total += w;
      if (_near(peakCents[i], v.partials)) explained += w;
    }
    var heard = 0.0;
    for (var k = 0; k < v.keyPartials.length; k++) {
      if (_near(v.keyPartials[k], peakCents)) heard += v.keyWeights[k];
    }
    final precision = explained / total;
    final recall = heard / v.totalKeyWeight;
    return math.sqrt(precision * recall);
  }

  bool _near(double cents, List<double> candidates) {
    for (final c in candidates) {
      if ((c - cents).abs() <= toleranceCents) return true;
    }
    return false;
  }

  List<ChordScore> rank(List<SpectralPeak> peaks) {
    final scores = [for (final c in chords) ChordScore(c, score(peaks, c))];
    scores.sort((a, b) => b.score.compareTo(a.score));
    return scores;
  }

  /// Passes when the expected chord scores at least [minScore] and no chord with a different set
  /// of notes scores better (within [margin]). Same-note voicings (A vs A barre) don't compete.
  ChordVerdict verify(List<SpectralPeak> peaks, Chord expected, {double minScore = 0.75, double margin = 0.02}) {
    final s = score(peaks, expected);
    final pcs = expected.pitchClasses;
    var best = expected;
    var bestScore = s;
    var bestOther = 0.0;
    for (final c in chords) {
      if (c.id == expected.id) continue;
      final cs = score(peaks, c);
      if (cs > bestScore) {
        best = c;
        bestScore = cs;
      }
      if (!_sameSet(c.pitchClasses, pcs) && cs > bestOther) bestOther = cs;
    }
    return ChordVerdict(matches: s >= minScore && s + margin >= bestOther, score: s, best: best);
  }

  static bool _sameSet(Set<int> a, Set<int> b) => a.length == b.length && a.containsAll(b);
}

/// Decides whether a frame contains a given single note.
class NoteMatcher {
  static bool matches(AnalysisFrame frame, int midi, {double centsTolerance = 50}) {
    final pitch = frame.pitch;
    if (pitch != null && pitch.clarity >= 0.85) {
      return (pitch.midi - midi).abs() * 100 <= centsTolerance;
    }
    // Several strings ringing (arpeggios): accept a strong peak at the expected fundamental.
    if (frame.peaks.isEmpty) return false;
    final loudest = frame.peaks.first.magnitude;
    for (final p in frame.peaks) {
      if (p.magnitude < 0.5 * loudest) break;
      if ((freqToMidi(p.frequency) - midi).abs() * 100 <= centsTolerance) return true;
    }
    return false;
  }
}
