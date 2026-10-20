import 'notes.dart';

class Barre {
  const Barre({required this.fret, required this.from, required this.to});

  final int fret;

  /// String numbers the barre spans, e.g. 6 -> 1 for a full barre.
  final int from;
  final int to;

  factory Barre.fromJson(Map<String, dynamic> json) =>
      Barre(fret: json['fret'] as int, from: json['from'] as int, to: json['to'] as int);
}

/// A chord voicing. [frets] and [fingers] run from string 6 (low E) to string 1.
class Chord {
  const Chord({
    required this.id,
    required this.name,
    required this.symbol,
    required this.category,
    required this.frets,
    required this.fingers,
    this.barre,
    this.tip,
  });

  final String id;
  final String name;
  final String symbol;
  final String category;
  final List<int> frets;
  final List<int> fingers;
  final Barre? barre;
  final String? tip;

  factory Chord.fromJson(Map<String, dynamic> json, {String? tip}) => Chord(
        id: json['id'] as String,
        name: json['name'] as String,
        symbol: (json['symbol'] ?? json['id']) as String,
        category: json['category'] as String,
        frets: List<int>.from(json['frets'] as List),
        fingers: List<int>.from(json['fingers'] as List),
        barre: json['barre'] == null ? null : Barre.fromJson(json['barre'] as Map<String, dynamic>),
        tip: tip,
      );

  /// MIDI notes of the strings that sound, low to high.
  List<int> get midiNotes => [
        for (var i = 0; i < 6; i++)
          if (frets[i] >= 0) midiAt(6 - i, frets[i]),
      ];

  Set<int> get pitchClasses => midiNotes.map(pitchClass).toSet();

  /// The lowest string the strum should start on (6..1).
  int get lowestString => 6 - frets.indexWhere((f) => f >= 0);

  /// First fret shown on a diagram: 1 for open-position shapes, else the lowest fretted fret.
  int get baseFret {
    final fretted = frets.where((f) => f > 0);
    if (fretted.isEmpty) return 1;
    final max = fretted.reduce((a, b) => a > b ? a : b);
    if (max <= 4) return 1;
    return fretted.reduce((a, b) => a < b ? a : b);
  }

  /// Plain-language placement, one line per finger, e.g. "Finger 2: string 5, fret 2".
  List<String> get placement {
    final lines = <String>[];
    if (barre != null) {
      lines.add('Finger 1: barre fret ${barre!.fret} from string ${barre!.from} to ${barre!.to}');
    }
    for (var i = 0; i < 6; i++) {
      final fret = frets[i];
      final finger = fingers[i];
      if (fret <= 0) continue;
      if (barre != null && finger == 1 && fret == barre!.fret) continue;
      lines.add('Finger $finger: string ${6 - i}, fret $fret');
    }
    lines.sort();
    final muted = [for (var i = 0; i < 6; i++) if (frets[i] < 0) 6 - i];
    if (muted.isNotEmpty) lines.add("Don't play string${muted.length > 1 ? 's' : ''} ${muted.join(', ')}");
    return lines;
  }
}
