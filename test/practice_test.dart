import 'dart:math' as math;

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
      expect(p.hits.map((h) => h.slot), [0, 2, 3, 5, 6, 7]);
      expect(p.hits[3].direction, StrumDirection.up);
      final times = p.expectedTimes(bpm: 60, bars: 1);
      expect(times, [4.0, 5.0, 5.5, 6.5, 7.0, 7.5]);
    });

    test('rejects patterns of the wrong length', () {
      expect(() => StrumPattern('D-D-', 4), throwsA(isA<AssertionError>()));
    });
  });

  group('StrumPattern', () {
    test('chucks, accents, sixteenths and swing', () {
      final chucks = StrumPattern('D-XU-UXU', 4, accents: '-->--->-');
      expect([for (final h in chucks.hits) (h.slot, h.muted, h.accent)],
          [(0, false, false), (2, true, true), (3, false, false), (5, false, false), (6, true, true), (7, false, false)]);
      expect(chucks.hits[1].direction, StrumDirection.down);

      final sixteenths = StrumPattern('D-DUD-DUD-DUD-DU', 4);
      expect(sixteenths.slotsPerBeat, 4);
      expect(sixteenths.expectedTimes(bpm: 60, bars: 1).take(3), [4.0, 4.5, 4.75]); // after the count-in bar
      expect(sixteenths.slotAt(1.6), 6); // beat 2, "&"
      expect(sixteenths.tolerance(80), closeTo(0.45 * 0.75 / 4, 1e-9)); // under half a sixteenth apart
      expect(StrumPattern('D-DU-UDU', 4).tolerance(80), 0.11); // eighths keep the usual window

      final shuffle = StrumPattern('DUDUDUDU', 4, swing: true);
      expect(shuffle.beatOf(1), closeTo(2 / 3, 1e-9));
      expect(shuffle.slotAt(0.6), 0); // still the long first part of the beat
      expect(shuffle.slotAt(0.7), 1);
      expect(shuffle.key, isNot(StrumPattern('DUDUDUDU', 4).key)); // cached audio can't mix them up
    });

    test('malformed patterns are rejected', () {
      expect(() => StrumPattern('D-DU-UDU', 4, accents: '>>'), throwsA(isA<AssertionError>()));
      expect(() => StrumPattern('D-DUD-DUD-DUD-DU', 4, swing: true), throwsA(isA<AssertionError>()));
      expect(() => StrumPattern('D-D', 4), throwsA(isA<AssertionError>()));
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

  test('StreamClock places onsets on the local clock without the delivery jitter', () {
    // 2048-sample frames delivered in 1920-sample chunks, 80 ms late, plus up to 15 ms waiting
    // for the UI thread: the per-frame "arrival minus frame end" wobbles by ~60 ms.
    const sr = 44100, hop = 2048, chunk = 1920, latency = 0.08;
    final rnd = math.Random(4);
    final clock = StreamClock();
    var worstNaive = 0.0, worst = 0.0;
    var nextFrame = hop;
    for (var end = chunk; end < sr * 20; end += chunk) {
      final arrival = end / sr + latency + rnd.nextDouble() * 0.015;
      for (; nextFrame <= end; nextFrame += hop) {
        final t = nextFrame / sr;
        clock.observe(t, arrival);
        final onset = t - 0.02; // a strum heard in this frame
        final truth = onset + latency;
        if (t > 2) {
          worstNaive = math.max(worstNaive, (arrival - (t - onset) - truth).abs());
          worst = math.max(worst, (clock.toLocal(onset) - truth).abs());
        }
      }
    }
    expect(worstNaive, greaterThan(0.04)); // what mapping each frame by its own arrival gave
    expect(worst, lessThan(0.002));
  });

  test('StreamClock starts over when the stream restarts', () {
    final clock = StreamClock()
      ..observe(10, 10.1)
      ..observe(0.5, 30.6); // the mic was reopened at local 30.1
    expect(clock.toLocal(0.2), closeTo(30.3, 1e-9));
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

    test('damaged saved progress does not stop the app from starting, and is kept', () async {
      const xpFor = {'{"xp":5}': 5, '{"stars":{"a":1.0},"xp":7.0}': 7, '[]': 0, 'not json': 0};
      for (final MapEntry(key: raw, value: xp) in xpFor.entries) {
        SharedPreferences.setMockInitialValues({'progress.v1': raw});
        final loaded = ProgressStore(await SharedPreferences.getInstance());
        expect(loaded.xp, xp, reason: raw);
        expect(loaded.starsFor('a'), raw.contains('"a"') ? 1 : 0, reason: raw);
      }
      SharedPreferences.setMockInitialValues({'progress.v1': '[]'});
      final prefs = await SharedPreferences.getInstance();
      ProgressStore(prefs);
      expect(prefs.getString('progress.v1.damaged'), '[]');
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

    test('the screen stays on, charts are upright and tabs have high e at the bottom, until changed', () async {
      expect(store.keepScreenOn, isTrue);
      expect(store.chordOrientation, ChordOrientation.upright);
      expect(store.stringOrder, StringOrder.lowOnTop);
      expect(store.keepPlaying, isFalse, reason: 'going back after misses, unless asked to keep playing');
      store.keepPlaying = true;
      store.keepScreenOn = false;
      store.chordOrientation = ChordOrientation.sideways;
      store.stringOrder = StringOrder.highOnTop;
      final again = ProgressStore(await SharedPreferences.getInstance());
      expect(again.keepScreenOn, isFalse);
      expect(again.keepPlaying, isTrue);
      expect(again.chordOrientation, ChordOrientation.sideways);
      expect(again.stringOrder, StringOrder.highOnTop);
    });

    test('the string order follows the default until the learner picks one', () async {
      store.leftHanded = true;
      final raw = (await SharedPreferences.getInstance()).getString('progress.v1')!;
      expect(raw, isNot(contains('stringOrder')), reason: 'never picked: not saved, so a new default applies');
    });

    test('string order: low E on top with high e going down, or high e on top', () {
      expect([for (var s = 1; s <= 6; s++) StringOrder.lowOnTop.row(s)], [5, 4, 3, 2, 1, 0]);
      expect([for (var s = 1; s <= 6; s++) StringOrder.highOnTop.row(s)], [0, 1, 2, 3, 4, 5]);
    });

    test('usage stats are shared until turned off, and a reset keeps the choice', () async {
      expect(store.shareUsage, isTrue);
      store.shareUsage = false;
      store.reset();
      expect(ProgressStore(await SharedPreferences.getInstance()).shareUsage, isFalse);
    });
  });

  test('going back a line: to its start, or to the line before when it has only just begun', () {
    final lines = SongLines([4, 4, 2, 0, 4]);
    expect(lines.bars, 14);
    expect([for (final b in [0, 5, 9, 13]) lines.startOf(b)], [0, 4, 8, 10]);
    expect([for (final b in [0, 5, 9, 13]) lines.endOf(b)], [4, 8, 10, 14]);
    expect(lines.back(6, 0.9), 4, reason: 'mid-line: back to its start');
    expect(lines.back(4, 0.8), 4, reason: 'well into the first bar: this line again');
    expect(lines.back(4, 0.2), 0, reason: 'only just begun: the line before');
    expect(lines.back(0, 0.1), 0, reason: 'nowhere further back than the top');
    expect((SongLines(const []).startOf(0), SongLines(const []).endOf(0)), (0, 0));
  });

  test('going back: after two misses in a row, and at most three times to the same place', () {
    final r = Rewinder();
    expect([r.record(false), r.record(true), r.record(false), r.record(false)], [false, false, false, true]);
    expect(r.back(8), isTrue);
    expect(r.record(false), isFalse, reason: 'the streak starts again after going back');
    expect(r.record(false), isTrue);
    expect([r.back(8), r.back(8), r.back(8)], [true, true, false], reason: 'three times back to bar 8, then carry on');
    expect(r.back(4), isTrue, reason: 'another place is a new place');
    r.reset();
    expect(r.back(8), isTrue, reason: 'a new run starts afresh');
  });

  test('notes are judged as the music passes them: heard in time is right, nothing is missed', () {
    var playing = -1;
    // Four quarter notes at 60 BPM (a beat a second): C, D, E and a G chord column.
    final judge = NoteJudge(
      beats: [0, 1, 2, 3],
      notes: [[60], [62], [64], [55, 59, 62]],
      matches: (f, midi) => midi == playing,
    )..secondsPerBeat = 1;
    const f = AnalysisFrame(time: 0, rms: 0.1);
    playing = 60;
    judge.hear(-0.1, f); // a touch early still counts
    playing = 64;
    judge.hear(1.5, f); // a wrong note in D's time
    expect(judge.judgeUpTo(2.5), [0, 1]);
    expect(judge.results.take(2), [true, false]);
    playing = 64;
    judge.hear(2.2, f);
    playing = 59;
    judge.hear(3.1, f); // any note of the chord
    expect(judge.judgeUpTo(9), [2, 3]);
    expect(judge.results, [true, false, true, true]);
    judge.restartAt(1);
    expect(judge.results, [true, null, null, null], reason: 'playing again from D judges it afresh');
    expect(judge.judgeUpTo(9, last: 2), [1, 2], reason: 'not past the end of the section');
  });

  test('a wrong note is a fresh pluck heard clearly as another note, not the last one ringing on', () {
    final wrong = WrongNote();
    bool wantD(AnalysisFrame f) => same(f, 'D');
    expect(wrong.hear(frame(0.0, 'C'), wantD), isFalse, reason: 'still ringing from before: no fresh pluck');
    expect(wrong.hear(frame(0.1, 'C'), wantD), isFalse);
    expect(wrong.hear(frame(0.5, 'C', onset: true), wantD), isFalse, reason: 'one frame is not enough to be sure');
    expect(wrong.hear(frame(0.55, 'C'), wantD), isTrue);
    wrong.reset();
    expect(wrong.hear(frame(1.0, 'D', onset: true), wantD), isFalse, reason: 'the right note is not wrong');
    expect(wrong.hear(frame(1.05, 'D'), wantD), isFalse);
    expect(wrong.hear(frame(2.0, 'C', onset: true), wantD), isFalse);
    expect(wrong.hear(frame(2.9, 'C'), wantD), isFalse, reason: 'long after the pluck it has stopped counting');
  });

  test('a tracker can jump back to try a part again', () {
    final t = SequenceTracker<int>(targets: [1, 2, 3], matcher: (f, n) => true);
    t.jumpTo(2);
    expect(t.current, 3);
    t.jumpTo(0);
    expect(t.current, 1);
    t.jumpTo(9);
    expect(t.done, isTrue);
  });

  test('stars thresholds', () {
    expect(starsFor(0.95), 3);
    expect(starsFor(0.75), 2);
    expect(starsFor(0.2), 1);
  });
}
