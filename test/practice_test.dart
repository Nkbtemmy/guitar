import 'package:flutter_test/flutter_test.dart';
import 'package:guitaro/audio/analysis.dart';
import 'package:guitaro/practice/trackers.dart';
import 'package:guitaro/progress/progress_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Frames carrying a fake "note" in pitch.frequency so the matcher is trivial.
AnalysisFrame frame(double t, String? heard, {bool onset = false}) => AnalysisFrame(
      time: t,
      rms: heard == null ? 0 : 0.1,
      pitch: heard == null ? null : PitchResult(heard.codeUnitAt(0).toDouble(), 1),
      peaks: heard == null ? const [] : const [SpectralPeak(100, 1)],
      onsets: onset ? [t - 0.01] : const [],
    );

bool same(AnalysisFrame f, String target) => f.pitch?.frequency == target.codeUnitAt(0).toDouble();

void main() {
  group('SequenceTracker', () {
    test('repeated targets each need a fresh attack', () {
      final t = SequenceTracker<String>(targets: ['A', 'A'], matcher: same);
      expect(t.process(frame(0.05, 'A', onset: true)), isFalse);
      expect(t.process(frame(0.10, 'A')), isTrue);
      // Holding the same note does not count as the second 'A'.
      for (var i = 0; i < 40; i++) {
        expect(t.process(frame(0.15 + i * 0.05, 'A')), isFalse);
      }
      t.process(frame(2.5, 'A', onset: true));
      expect(t.process(frame(2.55, 'A')), isTrue);
      expect(t.done, isTrue);
    });

    test('a wrong note after an attack does not advance; window expires', () {
      final t = SequenceTracker<String>(targets: ['A', 'B'], matcher: same, sustainSeconds: 10);
      t.process(frame(0.0, 'B', onset: true));
      t.process(frame(0.05, 'B'));
      expect(t.index, 0);
      t.process(frame(1.0, 'A'));
      t.process(frame(1.05, 'A'));
      expect(t.index, 0, reason: 'attack window (0.7 s) has expired');
    });

    test('holding a different target steadily counts even if the attack was missed', () {
      final t = SequenceTracker<String>(targets: ['A', 'B'], matcher: same);
      for (var i = 0; i <= 20; i++) {
        t.process(frame(i * 0.05, 'A'));
      }
      expect(t.index, 1);
    });
  });

  group('StrumPattern', () {
    test('parses hits and expected times after a count-in', () {
      final p = StrumPattern('D-DU-UDU', 4);
      expect(p.hits.map((h) => h.eighth), [0, 2, 3, 5, 6, 7]);
      expect(p.hits[3].direction, StrumDirection.up);
      final times = p.expectedTimes(bpm: 60, bars: 1);
      expect(times, [4.0, 5.0, 5.5, 6.5, 7.0, 7.5]);
    });

    test('rejects patterns of the wrong length', () {
      expect(() => StrumPattern('D-D-', 4), throwsA(isA<AssertionError>()));
    });
  });

  group('TimingScorer', () {
    test('compensates constant latency and counts misses and extras', () {
      final expected = [1.0, 1.5, 2.0, 2.5];
      final onsets = [1.12, 1.61, 2.13, 3.4];
      final r = TimingScorer.score(expected, onsets);
      expect(r.offset, closeTo(0.12, 0.011));
      expect(r.hit, [true, true, true, false]);
      expect(r.extra, 1);
      expect(r.accuracy, 0.75);
    });

    test('no onsets means zero', () {
      expect(TimingScorer.score([1, 2], const []).accuracy, 0);
    });
  });

  test('BarScorer ignores the change window at the start of each bar', () {
    final s = BarScorer(bars: 2, barSeconds: 2, startSeconds: 1);
    s.record(1.1, false); // inside grace period of bar 0, ignored
    s.record(2.0, true);
    s.record(2.5, true);
    s.record(3.6, false);
    s.record(4.0, false);
    expect(s.barCorrect(0), isTrue);
    expect(s.barCorrect(1), isFalse);
    expect(s.accuracy, 0.5);
    expect(s.barAt(0.5), -1);
    expect(s.barAt(5.1), -1);
  });

  group('ProgressStore', () {
    late ProgressStore store;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = ProgressStore(await SharedPreferences.getInstance());
    });

    test('keeps the best stars, awards first-completion bonus once', () {
      expect(store.completeLesson('a', 2), 40);
      expect(store.completeLesson('a', 1), 10);
      expect(store.starsFor('a'), 2);
      expect(store.xp, 50);
    });

    test('streak counts consecutive days and survives until the end of today', () {
      store.completeLesson('a', 3, now: DateTime(2026, 10, 18, 9));
      store.completeLesson('b', 3, now: DateTime(2026, 10, 19, 20));
      expect(store.streak(DateTime(2026, 10, 19, 21)), 2);
      expect(store.streak(DateTime(2026, 10, 20, 8)), 2);
      expect(store.streak(DateTime(2026, 10, 21, 8)), 0);
    });

    test('persists across instances', () async {
      store.completeLesson('a', 3);
      store.leftHanded = true;
      final again = ProgressStore(await SharedPreferences.getInstance());
      expect(again.starsFor('a'), 3);
      expect(again.leftHanded, isTrue);
    });
  });

  test('stars thresholds', () {
    expect(starsFor(0.95), 3);
    expect(starsFor(0.75), 2);
    expect(starsFor(0.2), 1);
  });
}
