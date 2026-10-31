import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What kind of thing was practised: a lesson's song, a song sheet, or a tab in a sheet.
enum SpotKind { song, sheet, tab }

/// Where something was practised, so practice can go straight back to it.
@immutable
class SpotPlace {
  const SpotPlace(this.kind, this.id, [this.index = 0]);
  const SpotPlace.song(String id) : this(SpotKind.song, id);
  const SpotPlace.sheet(String id) : this(SpotKind.sheet, id);
  const SpotPlace.tab(String sheetId, int index) : this(SpotKind.tab, sheetId, index);

  final SpotKind kind;

  /// The lesson song's id, or the sheet's.
  final String id;

  /// Which tab of the sheet.
  final int index;

  String get key => '${kind.name}:$id:$index';

  Map<String, Object> toJson() => {'k': kind.name, 'id': id, 'i': index};

  static SpotPlace fromJson(Map<String, dynamic> j) =>
      SpotPlace(SpotKind.values.byName(j['k'] as String), j['id'] as String, (j['i'] as num?)?.toInt() ?? 0);

  @override
  bool operator ==(Object other) => other is SpotPlace && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// A part the learner keeps missing: a line of a song (its bars [from] up to [to]) or a bar of
/// a tab (its notes [from]..[to]), with how often it went right and wrong.
class WeakSpot {
  WeakSpot({
    required this.place,
    required this.from,
    required this.to,
    required this.title,
    required this.detail,
    this.misses = 0,
    this.hits = 0,
    DateTime? last,
  }) : last = last ?? DateTime.now();

  final SpotPlace place;
  final int from, to;
  final String title, detail;
  int misses, hits;
  DateTime last;

  String get key => '${place.key}@$from';

  /// How much it needs practice: misses, less the times it has gone right since.
  double get need => misses - hits * 0.75;

  Map<String, Object> toJson() => {
        'place': place.toJson(),
        'from': from,
        'to': to,
        'title': title,
        'detail': detail,
        'misses': misses,
        'hits': hits,
        'last': last.millisecondsSinceEpoch,
      };

  static WeakSpot fromJson(Map<String, dynamic> j) => WeakSpot(
        place: SpotPlace.fromJson(Map<String, dynamic>.from(j['place'] as Map)),
        from: (j['from'] as num).toInt(),
        to: (j['to'] as num).toInt(),
        title: j['title'] as String,
        detail: j['detail'] as String,
        misses: (j['misses'] as num?)?.toInt() ?? 0,
        hits: (j['hits'] as num?)?.toInt() ?? 0,
        last: DateTime.fromMillisecondsSinceEpoch((j['last'] as num).toInt()),
      );
}

/// What the learner has practised, kept on the device: the parts they keep missing (to practise
/// next), and more as the practice tools record it.
class PracticeLog extends ChangeNotifier {
  PracticeLog([this._prefs]) {
    final raw = _prefs?.getString(_key);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      for (final s in j['spots'] as List? ?? const []) {
        try {
          final spot = WeakSpot.fromJson(Map<String, dynamic>.from(s as Map));
          _spots[spot.key] = spot;
        } catch (_) {
          // One damaged entry mustn't lose the rest.
        }
      }
    } catch (e) {
      // Damaged history mustn't stop the app from starting; keep the original, since the next
      // save overwrites it.
      debugPrint('PracticeLog: saved practice is damaged ($e)');
      _prefs?.setString('$_key.damaged', raw);
    }
  }

  static const _key = 'practice.v1';
  final SharedPreferences? _prefs;
  final _spots = <String, WeakSpot>{};

  /// How long a spot stays on the list without being played.
  static const forgetAfter = Duration(days: 30);

  /// The parts most worth practising, most needed first.
  List<WeakSpot> weakSpots({DateTime? now}) {
    final since = (now ?? DateTime.now()).subtract(forgetAfter);
    return _spots.values.where((s) => s.need > 0 && s.last.isAfter(since)).toList()
      ..sort((a, b) {
        final byNeed = b.need.compareTo(a.need);
        return byNeed != 0 ? byNeed : b.last.compareTo(a.last);
      });
  }

  /// Records how a part went: a bar of a song's line, or a note of a tab's bar.
  void recordSpot(SpotPlace place,
      {required int from, required int to, required String title, required String detail, required bool right, DateTime? now}) {
    final key = '${place.key}@$from';
    final spot = _spots[key] ??= WeakSpot(place: place, from: from, to: to, title: title, detail: detail);
    if (right) {
      spot.hits++;
    } else {
      spot.misses++;
    }
    spot.last = now ?? DateTime.now();
    _save();
  }

  /// Takes a spot off the list (practised enough, or the song is gone).
  void forget(WeakSpot spot) {
    _spots.remove(spot.key);
    _save();
  }

  void _save() {
    _prefs?.setString(_key, jsonEncode({'spots': [for (final s in _spots.values) s.toJson()]}));
    notifyListeners();
  }
}
