import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

import 'curriculum/models.dart';

/// Anonymous usage stats: how many people use the app, how far they get through the course and
/// which features they use. Only the ids of bundled lessons and songs and plain counts are sent;
/// never audio, song text, the titles of the learner's own songs, video links or anything
/// personal. This one sends nothing: the tests use it, and so does the app when Firebase can't
/// start.
class Analytics {
  const Analytics();

  /// Starts Firebase stats and crash reports, or returns an [Analytics] that sends nothing when
  /// Firebase can't start (e.g. a build that isn't connected to a Firebase project).
  static Future<Analytics> start({required bool enabled, FirebaseOptions? options}) async {
    try {
      await Firebase.initializeApp(options: options);
    } catch (e) {
      debugPrint('Analytics: Firebase did not start ($e)');
      return const Analytics();
    }
    if (!kDebugMode) {
      // Dart errors don't end the app, so they're reported as non-fatal: Crashlytics' crash-free
      // users then counts real crashes, which it catches natively.
      final crashes = FirebaseCrashlytics.instance;
      FlutterError.onError = crashes.recordFlutterError;
      PlatformDispatcher.instance.onError = (error, stack) {
        crashes.recordError(error, stack);
        return true;
      };
    }
    return FirebaseUsage()..enabled = enabled;
  }

  /// The learner's "Share anonymous usage stats" setting.
  set enabled(bool on) {}

  /// One of the home screen's tabs came into view.
  void tab(String name) {}

  void lessonStarted(Lesson lesson) {}

  void lessonCompleted(Lesson lesson, int stars) {}

  /// A song sheet opened: a bundled one ("pd:…") or one of the learner's own.
  void songOpened(String sheetId) {}

  /// A chord finder made a sheet. [source] is "mic" or "video".
  void chordsFound({required String source, required int chords, required bool melody}) {}
}

/// [Analytics] through Firebase.
class FirebaseUsage extends Analytics {
  FirebaseUsage();

  final _analytics = FirebaseAnalytics.instance;
  bool? _on;

  @override
  set enabled(bool on) {
    if (on == _on) return;
    _on = on;
    // Development runs would inflate the counts. Both settings persist across launches.
    _quietly(_analytics.setAnalyticsCollectionEnabled(on && !kDebugMode));
    _quietly(FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(on && !kDebugMode));
  }

  @override
  void tab(String name) => _quietly(_analytics.logScreenView(screenName: name));

  @override
  void lessonStarted(Lesson lesson) => _log('lesson_start', {'lesson_id': lesson.id});

  @override
  void lessonCompleted(Lesson lesson, int stars) => _log('lesson_complete', {'lesson_id': lesson.id, 'stars': stars});

  /// The learner's own songs are all "own": their ids and titles stay on the device.
  @override
  void songOpened(String sheetId) => _log('song_open', {'song': sheetId.startsWith('pd:') ? sheetId : 'own'});

  /// Firebase takes only text and numbers, so [melody] is 1 or 0.
  @override
  void chordsFound({required String source, required int chords, required bool melody}) =>
      _log('chords_found', {'source': source, 'chords': chords, 'melody': melody ? 1 : 0});

  void _log(String name, Map<String, Object> parameters) =>
      _quietly(_analytics.logEvent(name: name, parameters: parameters));

  /// Stats are never worth an error.
  static void _quietly(Future<void> sent) => unawaited(sent.catchError((Object e) => debugPrint('Analytics: $e')));
}
