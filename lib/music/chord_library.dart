import 'dart:convert';

import 'chord.dart';

class ChordLibrary {
  ChordLibrary(List<Chord> chords) : chords = List.unmodifiable(chords), _byId = {for (final c in chords) c.id: c};

  /// [chordsJson] is assets/data/chords.json, [tipsJson] the optional Qwen-written chord_tips.json.
  factory ChordLibrary.fromJson(String chordsJson, {String? tipsJson}) {
    final data = jsonDecode(chordsJson) as Map<String, dynamic>;
    final tips = tipsJson == null ? const <String, dynamic>{} : jsonDecode(tipsJson) as Map<String, dynamic>;
    return ChordLibrary([
      for (final c in data['chords'] as List)
        Chord.fromJson(c as Map<String, dynamic>, tip: tips[(c as Map)['id']] as String?),
    ]);
  }

  final List<Chord> chords;
  final Map<String, Chord> _byId;

  Chord? operator [](String id) => _byId[id];

  Chord byId(String id) => _byId[id] ?? (throw ArgumentError('Unknown chord "$id"'));

  bool contains(String id) => _byId.containsKey(id);

  static const categories = <String, String>{
    'open': 'Open chords',
    'easy': 'Easy versions',
    'seventh': '7th chords',
    'color': 'Color chords',
    'power': 'Power chords',
    'barre': 'Barre chords',
  };

  List<Chord> inCategory(String category) => chords.where((c) => c.category == category).toList();
}
