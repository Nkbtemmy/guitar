import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../curriculum/models.dart';

/// How chords are drawn: a fretboard box diagram, six-line tab, or both side by side.
enum ChordDisplay { both, tab, diagram }

/// Learner progress and settings, persisted as one JSON blob in shared preferences.
class ProgressStore extends ChangeNotifier {
  ProgressStore(this._prefs) {
    final raw = _prefs.getString(_key);
    if (raw != null) {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _stars.addAll((j['stars'] as Map).map((k, v) => MapEntry(k as String, v as int)));
      _xp = j['xp'] as int? ?? 0;
      _days.addAll(List<String>.from(j['days'] as List? ?? const []));
      _unlockAll = j['unlockAll'] as bool? ?? false;
      _leftHanded = j['leftHanded'] as bool? ?? false;
      _sensitivity = (j['sensitivity'] as num?)?.toDouble() ?? 0.5;
      _chordDisplay = ChordDisplay.values.asNameMap()[j['chordDisplay']] ?? ChordDisplay.both;
    }
  }

  static const _key = 'progress.v1';
  final SharedPreferences _prefs;
  final Map<String, int> _stars = {};
  final Set<String> _days = {};
  int _xp = 0;
  bool _unlockAll = false;
  bool _leftHanded = false;
  double _sensitivity = 0.5;
  ChordDisplay _chordDisplay = ChordDisplay.both;

  int get xp => _xp;
  bool get unlockAll => _unlockAll;
  bool get leftHanded => _leftHanded;
  ChordDisplay get chordDisplay => _chordDisplay;

  /// 0 (needs loud playing) .. 1 (hears soft playing, but also more noise).
  double get sensitivity => _sensitivity;

  int starsFor(String lessonId) => _stars[lessonId] ?? 0;
  bool isComplete(String lessonId) => _stars.containsKey(lessonId);
  int get lessonsCompleted => _stars.length;
  int get totalStars => _stars.values.fold(0, (a, b) => a + b);

  bool isUnlocked(Curriculum c, Lesson lesson) {
    if (_unlockAll) return true;
    final i = c.lessons.indexOf(lesson);
    return i <= 0 || isComplete(c.lessons[i - 1].id);
  }

  /// The first unfinished lesson, or null when the course is done.
  Lesson? nextLesson(Curriculum c) {
    for (final l in c.lessons) {
      if (!isComplete(l.id)) return l;
    }
    return null;
  }

  /// Consecutive practice days ending today (or yesterday, so the streak survives until tonight).
  int streak([DateTime? now]) {
    var day = _dateOnly(now ?? DateTime.now());
    if (!_days.contains(_fmt(day))) day = day.subtract(const Duration(days: 1));
    var n = 0;
    while (_days.contains(_fmt(day))) {
      n++;
      day = day.subtract(const Duration(days: 1));
    }
    return n;
  }

  /// Records a finished lesson; keeps the best star count. Returns XP earned.
  int completeLesson(String lessonId, int stars, {DateTime? now}) {
    final earned = 10 * stars + (isComplete(lessonId) ? 0 : 20);
    _stars[lessonId] = stars > starsFor(lessonId) ? stars : starsFor(lessonId);
    _xp += earned;
    _days.add(_fmt(_dateOnly(now ?? DateTime.now())));
    _save();
    return earned;
  }

  set unlockAll(bool v) => _update(() => _unlockAll = v);
  set leftHanded(bool v) => _update(() => _leftHanded = v);
  set chordDisplay(ChordDisplay v) => _update(() => _chordDisplay = v);
  set sensitivity(double v) => _update(() => _sensitivity = v.clamp(0.0, 1.0));

  void reset() => _update(() {
        _stars.clear();
        _days.clear();
        _xp = 0;
      });

  void _update(void Function() change) {
    change();
    _save();
  }

  void _save() {
    _prefs.setString(
        _key,
        jsonEncode({
          'stars': _stars,
          'xp': _xp,
          'days': _days.toList()..sort(),
          'unlockAll': _unlockAll,
          'leftHanded': _leftHanded,
          'sensitivity': _sensitivity,
          'chordDisplay': _chordDisplay.name,
        }));
    notifyListeners();
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
