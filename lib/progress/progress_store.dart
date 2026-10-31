import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../curriculum/models.dart';

/// How chords are drawn: a fretboard box diagram, six-line tab, or both side by side.
enum ChordDisplay { both, tab, diagram }

/// Which way chord diagrams face: upright like a chord book (low E on the left, frets going
/// down), or sideways like the guitar's neck (nut on the left, frets left to right).
enum ChordOrientation { upright, sideways }

/// Which string is drawn on top in tabs, sideways chord charts and fretboards: low E, with high
/// e going down to the bottom, or high e, the way tab is usually printed.
enum StringOrder {
  lowOnTop,
  highOnTop;

  /// Row of [string] (1 = high e .. 6 = low E), counting from 0 at the top.
  int row(int string) => this == lowOnTop ? 6 - string : string - 1;
}

/// Learner progress and settings, persisted as one JSON blob in shared preferences.
class ProgressStore extends ChangeNotifier {
  ProgressStore(this._prefs) {
    final raw = _prefs.getString(_key);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      (j['stars'] as Map? ?? const {}).forEach((k, v) => _stars[k as String] = (v as num).toInt());
      _xp = (j['xp'] as num?)?.toInt() ?? 0;
      _days.addAll(List<String>.from(j['days'] as List? ?? const []));
      _unlockAll = j['unlockAll'] as bool? ?? false;
      _leftHanded = j['leftHanded'] as bool? ?? false;
      _sensitivity = ((j['sensitivity'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0);
      _openingSound = j['openingSound'] as bool? ?? true;
      _shareUsage = j['shareUsage'] as bool? ?? true;
      _keepScreenOn = j['keepScreenOn'] as bool? ?? true;
      _keepPlaying = j['keepPlaying'] as bool? ?? false;
      _chordOrientation = ChordOrientation.values.asNameMap()[j['chordChart']] ?? ChordOrientation.upright;
      _stringOrder = StringOrder.values.asNameMap()[j['stringOrder']];
      _chordDisplay = ChordDisplay.values.asNameMap()[j['chordDisplay']] ?? ChordDisplay.both;
    } catch (e) {
      // Damaged progress mustn't stop the app from starting. Carry on with what was read, and
      // keep the original, since the next save overwrites it.
      debugPrint('ProgressStore: saved progress is damaged ($e)');
      _prefs.setString('$_key.damaged', raw);
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
  bool _openingSound = true;
  bool _shareUsage = true;
  bool _keepScreenOn = true;
  bool _keepPlaying = false;
  ChordOrientation _chordOrientation = ChordOrientation.upright;
  // Null until the learner picks one, so it follows the app's default until then.
  StringOrder? _stringOrder;
  ChordDisplay _chordDisplay = ChordDisplay.both;

  int get xp => _xp;
  bool get unlockAll => _unlockAll;
  bool get leftHanded => _leftHanded;

  /// Strum the open strings on the splash screen.
  bool get openingSound => _openingSound;

  /// Send anonymous usage stats and crash reports (see `Analytics`).
  bool get shareUsage => _shareUsage;

  /// Keep the screen awake while the app is open: both hands are on the guitar.
  bool get keepScreenOn => _keepScreenOn;

  /// Playing along, carry on through missed notes and bars (they just turn red) instead of
  /// going back to try them again; in Learn, move on after a wrong note instead of waiting.
  bool get keepPlaying => _keepPlaying;
  ChordOrientation get chordOrientation => _chordOrientation;
  StringOrder get stringOrder => _stringOrder ?? StringOrder.lowOnTop;
  ChordDisplay get chordDisplay => _chordDisplay;

  /// 0 (needs loud playing) .. 1 (hears soft playing, but also more noise).
  double get sensitivity => _sensitivity;

  int starsFor(String lessonId) => _stars[lessonId] ?? 0;
  bool isComplete(String lessonId) => _stars.containsKey(lessonId);
  int get lessonsCompleted => _stars.length;
  int get totalStars => _stars.values.fold(0, (a, b) => a + b);

  /// Open once the lesson before it is done. A lesson already done stays open, even when a new
  /// lesson is added in front of it.
  bool isUnlocked(Curriculum c, Lesson lesson) {
    if (_unlockAll || isComplete(lesson.id)) return true;
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
  set openingSound(bool v) => _update(() => _openingSound = v);
  set shareUsage(bool v) => _update(() => _shareUsage = v);
  set keepScreenOn(bool v) => _update(() => _keepScreenOn = v);
  set keepPlaying(bool v) => _update(() => _keepPlaying = v);
  set chordOrientation(ChordOrientation v) => _update(() => _chordOrientation = v);
  set stringOrder(StringOrder v) => _update(() => _stringOrder = v);
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
          'openingSound': _openingSound,
          'shareUsage': _shareUsage,
          'keepScreenOn': _keepScreenOn,
          'keepPlaying': _keepPlaying,
          'chordChart': _chordOrientation.name,
          if (_stringOrder != null) 'stringOrder': _stringOrder!.name,
          'chordDisplay': _chordDisplay.name,
        }));
    notifyListeners();
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
