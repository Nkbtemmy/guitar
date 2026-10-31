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

/// A minute of chord changes: how many clean changes, and when.
typedef ChangeRun = ({DateTime at, int count});

/// A recording of the learner playing. The audio is a file named after [id] (see `Takes`); this
/// is what's known about it.
class Take {
  Take({required this.id, required this.title, required this.created, required this.seconds, this.note = '', this.favourite = false});

  final String id;
  String title;
  final DateTime created;
  final double seconds;

  /// How the run went, when it was a play-along.
  String note;
  bool favourite;

  Map<String, Object> toJson() => {
        'id': id,
        'title': title,
        'created': created.millisecondsSinceEpoch,
        'seconds': seconds,
        'note': note,
        'favourite': favourite,
      };

  static Take fromJson(Map<String, dynamic> j) => Take(
        id: j['id'] as String,
        title: j['title'] as String,
        created: DateTime.fromMillisecondsSinceEpoch((j['created'] as num).toInt()),
        seconds: (j['seconds'] as num).toDouble(),
        note: j['note'] as String? ?? '',
        favourite: j['favourite'] as bool? ?? false,
      );
}

/// Something a teacher set: a song (or a tab) to play through at [tempo] (a share of its full
/// speed), by [due]. It's done when the learner manages it, or when ticked off by hand.
class Homework {
  Homework({
    required this.id,
    required this.place,
    required this.title,
    this.tempo = 1.0,
    this.due,
    this.note = '',
    this.done = false,
    DateTime? created,
  }) : created = created ?? DateTime.now();

  final String id;
  final SpotPlace place;
  final String title;
  final double tempo;
  final DateTime? due;
  final String note;
  bool done;
  final DateTime created;

  Map<String, Object?> toJson() => {
        'id': id,
        'place': place.toJson(),
        'title': title,
        'tempo': tempo,
        'due': due?.millisecondsSinceEpoch,
        'note': note,
        'done': done,
        'created': created.millisecondsSinceEpoch,
      };

  static Homework fromJson(Map<String, dynamic> j) => Homework(
        id: j['id'] as String,
        place: SpotPlace.fromJson(Map<String, dynamic>.from(j['place'] as Map)),
        title: j['title'] as String,
        tempo: (j['tempo'] as num?)?.toDouble() ?? 1.0,
        due: j['due'] == null ? null : DateTime.fromMillisecondsSinceEpoch((j['due'] as num).toInt()),
        note: j['note'] as String? ?? '',
        done: j['done'] as bool? ?? false,
        created: DateTime.fromMillisecondsSinceEpoch((j['created'] as num).toInt()),
      );
}

/// What the learner has practised, kept on the device: the parts they keep missing (to practise
/// next), their chord-change minutes, homework, and more as the practice tools record it.
class PracticeLog extends ChangeNotifier {
  PracticeLog([this._prefs]) {
    final raw = _prefs?.getString(_key);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      for (final MapEntry(:key, :value) in (j['seconds'] as Map? ?? const {}).entries) {
        _seconds[key as String] = (value as num).toInt();
      }
      for (final MapEntry(:key, :value) in (j['done'] as Map? ?? const {}).entries) {
        _done[key as String] = {for (final item in value as List) item as String};
      }
      for (final h in j['homework'] as List? ?? const []) {
        try {
          _homework.add(Homework.fromJson(Map<String, dynamic>.from(h as Map)));
        } catch (_) {}
      }
      for (final t in j['takes'] as List? ?? const []) {
        try {
          _takes.add(Take.fromJson(Map<String, dynamic>.from(t as Map)));
        } catch (_) {}
      }
      for (final MapEntry(:key, :value) in (j['bests'] as Map? ?? const {}).entries) {
        _bests[key as String] = (value as num).toInt();
      }
      for (final MapEntry(:key, :value) in (j['changes'] as Map? ?? const {}).entries) {
        _changes[key as String] = [
          for (final r in value as List)
            (at: DateTime.fromMillisecondsSinceEpoch(((r as List)[0] as num).toInt()), count: (r[1] as num).toInt()),
        ];
      }
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
  final _changes = <String, List<ChangeRun>>{};
  final _bests = <String, int>{};
  final _takes = <Take>[];
  final _homework = <Homework>[];

  /// Seconds practised, and plan items done, by day ("2026-10-31").
  final _seconds = <String, int>{};
  final _done = <String, Set<String>>{};

  static String _day(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  /// Adds time spent practising (playing while Guitaro listened) to today.
  void addPractice(Duration d, {DateTime? now}) {
    if (d <= Duration.zero) return;
    final day = _day(now ?? DateTime.now());
    // Anything past a few hours is the phone left listening, not practice.
    _seconds[day] = ((_seconds[day] ?? 0) + d.inSeconds).clamp(0, 6 * 3600);
    _save();
  }

  Duration practicedOn(DateTime day) => Duration(seconds: _seconds[_day(day)] ?? 0);

  /// Time practised in the [days] days up to and including [now]'s.
  Duration practicedOver(int days, {DateTime? now}) {
    final today = now ?? DateTime.now();
    var total = Duration.zero;
    for (var i = 0; i < days; i++) {
      total += practicedOn(DateTime(today.year, today.month, today.day - i));
    }
    return total;
  }

  /// Ticks a plan item off for today.
  void markDone(String item, {DateTime? now}) {
    if ((_done[_day(now ?? DateTime.now())] ??= {}).add(item)) _save();
  }

  bool isDone(String item, {DateTime? now}) => _done[_day(now ?? DateTime.now())]?.contains(item) ?? false;

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

  /// Chord changes are the same exercise either way round: C to G is G to C.
  static String pairKey(String a, String b) => ([a, b]..sort()).join('|');

  /// The minutes of changes between [a] and [b], oldest first.
  List<ChangeRun> changeRuns(String a, String b) => List.unmodifiable(_changes[pairKey(a, b)] ?? const <ChangeRun>[]);

  int? bestChanges(String a, String b) {
    final runs = _changes[pairKey(a, b)];
    return runs == null || runs.isEmpty ? null : runs.map((r) => r.count).reduce((x, y) => x > y ? x : y);
  }

  /// Every pair practised, most recent first.
  List<(String, String)> get changePairs {
    final pairs = _changes.entries.where((e) => e.value.isNotEmpty).toList()
      ..sort((x, y) => y.value.last.at.compareTo(x.value.last.at));
    return [
      for (final e in pairs)
        if (e.key.split('|') case [final a, final b]) (a, b),
    ];
  }

  /// The pair practised most recently, as (a, b).
  (String, String)? get lastChangePair {
    MapEntry<String, List<ChangeRun>>? latest;
    for (final e in _changes.entries) {
      if (e.value.isNotEmpty && (latest == null || e.value.last.at.isAfter(latest.value.last.at))) latest = e;
    }
    if (latest == null) return null;
    final [a, b] = latest.key.split('|');
    return (a, b);
  }

  /// Records a minute of [count] changes between [a] and [b]; true when it beats the best.
  bool recordChanges(String a, String b, int count, {DateTime? now}) {
    final best = bestChanges(a, b);
    final runs = _changes[pairKey(a, b)] ??= [];
    runs.add((at: now ?? DateTime.now(), count: count));
    // Enough history for a chart; older minutes only add bulk.
    if (runs.length > 60) runs.removeAt(0);
    _save();
    return best == null ? count > 0 : count > best;
  }

  /// Homework still to do first (soonest due first), then what's done.
  List<Homework> get homework => [..._homework]..sort((a, b) {
      if (a.done != b.done) return a.done ? 1 : -1;
      final ad = a.due ?? DateTime(9999), bd = b.due ?? DateTime(9999);
      return ad.compareTo(bd);
    });

  void addHomework(Homework h) {
    _homework.add(h);
    _save();
  }

  void removeHomework(Homework h) {
    _homework.removeWhere((x) => x.id == h.id);
    _save();
  }

  void setHomeworkDone(Homework h, bool done) {
    h.done = done;
    _save();
  }

  /// A run of [place] from beginning to end at [tempo] (share of full speed) with [accuracy] of
  /// it right: the homework there it meets is done. Returns that homework.
  List<Homework> completeHomework(SpotPlace place, {required double tempo, required double accuracy}) {
    final met = [
      for (final h in _homework)
        if (!h.done && h.place == place && tempo >= h.tempo - 1e-6 && accuracy >= 0.8) h,
    ];
    if (met.isEmpty) return met;
    for (final h in met) {
      h.done = true;
    }
    _save();
    return met;
  }

  /// The learner's recordings, newest first.
  List<Take> get takes => List.unmodifiable(_takes.reversed);

  void addTake(Take take) {
    _takes.add(take);
    _save();
  }

  void removeTake(Take take) {
    _takes.removeWhere((t) => t.id == take.id);
    _save();
  }

  /// Saves a change to [take] (renamed, starred).
  void updateTake(Take take) => _save();

  /// The best score in game [game] (the fretboard game, ear training…), if played.
  int? best(String game) => _bests[game];

  /// Records a score in [game]; true when it's a new best.
  bool recordBest(String game, int score) {
    final old = _bests[game];
    if (old != null && score <= old) return false;
    _bests[game] = score;
    _save();
    return score > 0;
  }

  void _save() {
    _prefs?.setString(
        _key,
        jsonEncode({
          'spots': [for (final s in _spots.values) s.toJson()],
          'bests': _bests,
          'takes': [for (final t in _takes) t.toJson()],
          'homework': [for (final h in _homework) h.toJson()],
          'seconds': _seconds,
          // Only the last few weeks' plans matter.
          'done': {
            for (final MapEntry(:key, :value) in _done.entries)
              if (key.compareTo(_day(DateTime.now().subtract(const Duration(days: 30)))) >= 0) key: value.toList(),
          },
          'changes': {
            for (final MapEntry(:key, :value) in _changes.entries) key: [for (final r in value) [r.at.millisecondsSinceEpoch, r.count]],
          },
        }));
    notifyListeners();
  }
}
