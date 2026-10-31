import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../audio/analysis.dart';
import '../../audio/chord_matcher.dart';
import '../../audio/mic_listener.dart';
import '../../music/notes.dart';
import '../../practice/takes.dart';
import '../../practice/trackers.dart';
import '../../progress/practice_log.dart';
import '../../progress/progress_store.dart';
import '../../sheets/tab_sequence.dart';
import '../theme.dart';
import '../widgets/listening.dart';
import '../widgets/listening_badge.dart';
import '../widgets/tab_highway.dart';

/// How the tab plays: Learn waits for each note to be played; the others play it at a speed.
enum TabSpeed {
  learn('Learn', 0),
  slower('Slower', 0.75),
  normal('Normal', 1),
  faster('Faster', 1.25);

  const TabSpeed(this.label, this.factor);

  final String label;
  final double factor;
}

/// Plays a tab as a highway scrolling past the play line: pause, Learn (waits for you) or a
/// speed, back and forward a bar, and a slider to go anywhere. A practice loop (A–B), count-in
/// and metronome too.
///
/// While it plays it listens: each note turns green when the learner plays it, red when it's
/// missed, and after three missed in a row it goes back about ten seconds and carries on (see
/// [Rewinder]). With Me's "Keep playing when I miss" on, it never goes back, and Learn moves on
/// after a wrong note instead of waiting for the right one.
class TabPlayerScreen extends StatefulWidget {
  const TabPlayerScreen({
    super.key,
    required this.tab,
    required this.title,
    this.bpm = 90,
    this.beatsPerBar = 4,
    this.id = 'tab',
    this.place,
    this.from,
    this.to,
    this.tuning = Tuning.standard,
  });

  final TabSequence tab;
  final String title;

  /// Tempo at 100% speed.
  final int bpm;
  final int beatsPerBar;

  /// Cache key for the rendered audio.
  final String id;

  /// Where this tab lives, so the bars the learner keeps missing are kept as weak spots.
  final SpotPlace? place;

  /// Open on notes [from]..[to], looping them (practising a weak spot).
  final int? from, to;

  /// How the guitar is tuned for this tab: it sounds, and is listened for, in this tuning.
  final Tuning tuning;

  @override
  State<TabPlayerScreen> createState() => _TabPlayerScreenState();
}

class _TabPlayerScreenState extends State<TabPlayerScreen> with SingleTickerProviderStateMixin {
  late final AppServices _services;
  late final Ticker _ticker = createTicker(_tick);
  final _clock = Stopwatch();
  // A weak spot from a song edited since may point past its end: keep the section inside it.
  late RangeValues _loop = () {
    final last = widget.tab.events.length - 1;
    final from = (widget.from ?? 0).clamp(0, last);
    return RangeValues(from.toDouble(), (widget.to ?? last).clamp(from, last).toDouble());
  }();
  TabSpeed _speed = TabSpeed.slower;
  late bool _looping = widget.from != null;
  bool _countIn = true, _metronome = false, _rendering = false;

  /// Where the music is, in beats: the highway follows it.
  final _position = ValueNotifier<double>(0);

  /// The event the current pass starts from, and the beats of count-in before it.
  int _passFrom = 0;
  double _lead = 0;
  int _passes = 0;

  /// Dragging the slider pauses; letting go carries on if it was playing.
  bool _resumeAfterDrag = false;

  /// How each note went, judged as the music passes it.
  late final _judge = NoteJudge(
    beats: [for (var i = 0; i < widget.tab.events.length; i++) _beatOf(i)],
    notes: [for (var i = 0; i < widget.tab.events.length; i++) _notesOf(widget.tab.events[i])],
    matches: NoteMatcher.matches,
  );
  final _rewinder = Rewinder(misses: 3);
  final _stream = StreamClock();
  final _wrong = WrongNote();

  bool get _keepPlaying => context.read<ProgressStore>().keepPlaying;

  /// Play the tune along with the learner (best with headphones), or keep time with clicks only,
  /// so the mic hears just them.
  bool _tune = true;

  /// What happened: gone back, or how the run went.
  String? _notice;

  /// The note this run started from (going back doesn't start a new run).
  int _runFrom = 0;

  /// While looping: after a clean pass, play the next one a little faster ([_trained]).
  bool _speedUp = false;
  double? _trained;

  /// Record the run as a take ([_take] while it records, and where it's kept).
  bool _record = false;
  ({String id, MicListener mic, PracticeLog log})? _take;

  void _finishTake([String note = '']) {
    final take = _take;
    if (take == null) return;
    _take = null;
    Takes.finish(take.mic, take.log, take.id, title: widget.title, note: note);
  }

  /// Learn: the notes to play, one at a time.
  late final _learn = SequenceTracker<TabEvent>(
    targets: widget.tab.events,
    matcher: (f, e) => _notesOf(e).any((m) => NoteMatcher.matches(f, m)),
    requiredFrames: 1,
  );
  String? _heard;

  late final List<HighwayNote> _notes = [
    for (var i = 0; i < widget.tab.events.length; i++) HighwayNote(_beatOf(i), widget.tab.events[i].frets, label: widget.tab.labels[i]),
  ];
  late final List<double> _bars = [for (final i in widget.tab.barStarts) _beatOf(i)];

  @override
  void initState() {
    super.initState();
    _services = context.read<AppServices>();
    _position.value = _beatOf(_from);
  }

  /// What [e] sounds as, in this tab's tuning.
  List<int> _notesOf(TabEvent e) => [for (final MapEntry(key: string, value: fret) in e.frets.entries) widget.tuning.midiAt(string, fret)];

  double _beatOf(int event) => widget.tab.events[event].column / TabSequence.columnsPerBeat;
  double get _factor => _trained ?? _speed.factor;
  int get _bpm => (widget.bpm * (_learning ? 1 : _factor)).round().clamp(20, 300);
  int get _from => _loop.start.round();
  int get _to => _loop.end.round();
  bool get _playing => _clock.isRunning;
  bool get _learning => _speed == TabSpeed.learn;
  double get _lastBeat => _beatOf(widget.tab.events.length - 1);

  /// Where Back and Forward count from: the note to play in Learn, else the music's position.
  double get _now => _learning ? _beatOf(_learn.index.clamp(0, widget.tab.events.length - 1)) : _position.value;

  /// The first event at or after [beat], within the section.
  int _eventAt(double beat) {
    for (var i = _from; i <= _to; i++) {
      if (_beatOf(i) >= beat - 1e-6) return i;
    }
    return _from;
  }

  /// Plays from [from] (or where the music is); [fresh] starts a new run rather than carrying on
  /// after going back.
  Future<void> _play({int? from, bool fresh = true}) async {
    final start = from ?? _eventAt(_position.value);
    if (fresh) {
      _rewinder.reset();
      _notice = null;
      _runFrom = start;
    }
    if (_record && _take == null) {
      final mic = context.read<MicListener>(), log = context.read<PracticeLog>();
      final id = await Takes.start(mic);
      if (!mounted) return;
      _take = (id: id, mic: mic, log: log);
    }
    setState(() => _rendering = true);
    try {
      await _startPass(start, countIn: _countIn);
    } finally {
      if (mounted) setState(() => _rendering = false);
    }
    if (mounted && !_ticker.isActive) _ticker.start();
  }

  Future<void> _startPass(int from, {required bool countIn}) async {
    if (_tune) {
      await _services.player.playTab(
        widget.id,
        widget.tab,
        bpm: _bpm,
        from: from,
        to: _to,
        beatsPerBar: widget.beatsPerBar,
        countIn: countIn,
        metronome: _metronome,
        listening: true,
        tuning: widget.tuning,
      );
    } else {
      // Clicks only: a bar to count in, then the passage.
      await _services.player.playClickTrack(
          bpm: _bpm, beatsPerBar: widget.beatsPerBar, bars: ((_beatOf(_to) - _beatOf(from)) / widget.beatsPerBar).ceil() + 1);
    }
    _passFrom = from;
    _lead = countIn || !_tune ? widget.beatsPerBar.toDouble() : 0;
    _judge
      ..secondsPerBeat = 60 / _bpm
      ..restartAt(from);
    _passes++;
    _clock
      ..reset()
      ..start();
  }

  /// Stops where it is: Play carries on from here. A take being recorded ends, unless the run
  /// is only going back ([keepTake]).
  void _pause({bool keepTake = false}) {
    _clock.stop();
    _ticker.stop();
    _services.player.stop();
    if (!keepTake) _finishTake();
    setState(() => _passes = 0);
  }

  void _tick(Duration _) {
    if (_learning) {
      // Glide to the note to play, then rest until it changes.
      final target = _learn.done ? _lastBeat + 1 : _beatOf(_learn.index);
      final pos = _position.value;
      if ((target - pos).abs() > 0.01) {
        _position.value = pos + (target - pos) * 0.2;
      } else {
        _position.value = target;
        _ticker.stop();
      }
      return;
    }
    if (!_playing) return;
    final beats = _clock.elapsedMicroseconds / 1e6 * _bpm / 60 - _lead;
    final now = _beatOf(_passFrom) + beats;
    _position.value = now;
    // Judge each note a moment after it stops ringing: the mic runs a little behind.
    for (final i in _judge.judgeUpTo(now - 0.25 * _bpm / 60, last: _to)) {
      _remember(i, _judge.results[i]!);
      if (!_keepPlaying && !_looping && _rewinder.record(_judge.results[i]!) && _goBack(now)) return;
    }
    if (beats * 60 / _bpm >= widget.tab.durationOf(_bpm, from: _passFrom, to: _to)) {
      if (_looping) {
        _clock.stop();
        // The pass's last notes, before the next pass judges them afresh.
        for (final i in _judge.judgeUpTo(double.infinity, last: _to)) {
          _remember(i, _judge.results[i]!);
        }
        final right = _judge.results.sublist(_from, _to + 1).where((r) => r == true).length;
        if (_speedUp && right >= 0.9 * (_to - _from + 1) && _factor < 1.5) {
          setState(() {
            _trained = math.min(1.5, _factor + 0.05);
            _notice = 'Clean! Speeding up to $_bpm BPM.';
          });
        }
        _startPass(_from, countIn: false);
      } else {
        _judge.judgeUpTo(double.infinity, last: _to);
        final right = _judge.results.sublist(_runFrom, _to + 1).where((r) => r == true).length;
        final total = _to - _runFrom + 1;
        // Played from beginning to end: it may be the homework.
        final whole = _runFrom == 0 && _to == widget.tab.events.length - 1;
        final homework = whole &&
            widget.place != null &&
            context.read<PracticeLog>().completeHomework(widget.place!, tempo: _factor, accuracy: right / total).isNotEmpty;
        _notice = 'You played $right of $total notes right.${homework ? ' Homework done!' : ''}';
        _finishTake('$right of $total notes right');
        _pause();
      }
    }
  }

  /// Back about ten seconds, to the start of a bar, and on from there. False when it has gone
  /// back there enough times already: then the music carries on.
  bool _goBack(double now) {
    final starts = [0.0, ..._bars];
    final bar = starts.lastIndexWhere((b) => b <= now - Rewinder.seconds * _bpm / 60 + 1e-6);
    final event = _eventAt(starts[bar < 0 ? 0 : bar]);
    if (!_rewinder.back(event)) return false;
    _pause(keepTake: true);
    _notice = 'Missed a few notes: back to bar ${(bar < 0 ? 0 : bar) + 1}. Keep going!';
    _position.value = _beatOf(event);
    _play(from: event, fresh: false);
    return true;
  }

  /// Goes to [beat]: playing carries on from there, Learn waits for the note there.
  void _seek(double beat) {
    final event = _eventAt(beat);
    if (_learning) {
      setState(() {
        _learn.jumpTo(event);
        _judge.restartAt(event);
      });
      _wrong.reset();
      _glide();
      return;
    }
    final wasPlaying = _playing;
    if (wasPlaying) _pause();
    _position.value = _beatOf(event);
    if (wasPlaying) _play(from: event);
  }

  /// The start of the bar playing, or the bar before when this one has only just begun.
  void _back() {
    final now = _now;
    final starts = [0.0, ..._bars];
    final current = starts.lastWhere((b) => b <= now + 1e-6, orElse: () => 0);
    final previous = starts.lastWhere((b) => b < current - 1e-6, orElse: () => 0);
    _seek(now - current < 1 ? previous : current);
  }

  void _forward() {
    final now = _now;
    final next = _bars.where((b) => b > now + 1e-6).firstOrNull;
    if (next != null) _seek(next);
  }

  void _setSpeed(TabSpeed speed) {
    final wasPlaying = _playing;
    if (wasPlaying) _pause();
    setState(() {
      _speed = speed;
      _trained = null;
      _heard = null;
      if (speed == TabSpeed.learn) {
        final event = _eventAt(_position.value);
        _learn.jumpTo(event);
        _judge.restartAt(event);
        _wrong.reset();
      }
    });
    if (speed == TabSpeed.learn) {
      _glide();
    } else {
      _ticker.stop();
      if (wasPlaying) _play();
    }
  }

  void _hear(AnalysisFrame f) {
    final p = f.pitch;
    final heard = p != null && p.clarity >= 0.85 ? 'Heard: ${noteNameWithOctave(p.midi.round())}' : null;
    var advanced = false;
    if (_learning) {
      final note = _learn.index;
      advanced = _learn.process(f);
      if (advanced) {
        _judge.results[note] = true;
        _remember(note, true);
      } else if (_keepPlaying &&
          !_learn.done &&
          _wrong.hear(f, (f) => _notesOf(_learn.current!).any((m) => NoteMatcher.matches(f, m)))) {
        // Keeping going: a wrong note moves on too, marked red.
        _judge.results[note] = false;
        _remember(note, false);
        _learn.jumpTo(note + 1);
        advanced = true;
      }
      if (advanced) {
        _wrong.reset();
        _glide();
      }
    } else if (_playing) {
      // Frames arrive a jittery while after they were heard: place them on the music's clock.
      _stream.observe(f.time, _clock.elapsedMicroseconds / 1e6);
      _judge.hear(_beatOf(_passFrom) + _stream.toLocal(f.time) * _bpm / 60 - _lead, f);
    }
    if (advanced || heard != _heard) setState(() => _heard = heard);
  }

  /// Counts note [i] towards its bar's weak spot.
  void _remember(int i, bool right) {
    final place = widget.place;
    if (place == null) return;
    final starts = [0, ...widget.tab.barStarts];
    final bar = starts.lastIndexWhere((s) => s <= i);
    final to = bar + 1 < starts.length ? starts[bar + 1] - 1 : widget.tab.events.length - 1;
    context.read<PracticeLog>()
        .recordSpot(place, from: starts[bar], to: to, title: widget.title, detail: 'Bar ${bar + 1}', right: right);
  }

  /// Learn: move the highway to the note to play.
  void _glide() {
    if (!_ticker.isActive) _ticker.start();
  }

  @override
  void dispose() {
    _clock.stop();
    _services.player.stop();
    _finishTake();
    _ticker.dispose();
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = widget.tab.events.length - 1;
    final keepPlaying = context.select<ProgressStore, bool>((p) => p.keepPlaying);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(children: [
              IconButton.filled(
                tooltip: _playing ? 'Pause' : 'Play',
                onPressed: _learning || _rendering ? null : (_playing ? _pause : _play),
                icon: _rendering
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kOnAccent))
                    : Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SegmentedButton<TabSpeed>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact, padding: WidgetStatePropertyAll(EdgeInsets.zero)),
                  segments: [for (final s in TabSpeed.values) ButtonSegment(value: s, label: FittedBox(child: Text(s.label)))],
                  selected: {_speed},
                  onSelectionChanged: (v) => _setSpeed(v.first),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Stack(children: [
              TabHighway(notes: _notes, position: _position, bars: _bars, results: List.of(_judge.results), height: 210),
              // The count-in, over what has been played.
              Positioned(
                left: 12,
                top: 0,
                child: ValueListenableBuilder<double>(
                  valueListenable: _position,
                  builder: (context, pos, _) {
                    final before = _beatOf(_passFrom) - pos;
                    if (!_playing || before <= 0) return const SizedBox.shrink();
                    return Text('${widget.beatsPerBar - before.ceil() + 1}',
                        style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: kAccent));
                  },
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              IconButton(tooltip: 'Back a bar', onPressed: _back, icon: const Icon(Icons.fast_rewind_rounded)),
              Expanded(
                child: ValueListenableBuilder<double>(
                  valueListenable: _position,
                  builder: (context, pos, _) => Slider(
                    value: pos.clamp(0, _lastBeat),
                    max: _lastBeat <= 0 ? 1 : _lastBeat,
                    onChangeStart: (_) {
                      if (_playing) {
                        _pause();
                        _resumeAfterDrag = true;
                      }
                    },
                    onChanged: (v) => _learning ? _seek(v) : _position.value = v,
                    onChangeEnd: (v) {
                      if (_learning) return;
                      _position.value = _beatOf(_eventAt(v));
                      if (_resumeAfterDrag) _play();
                      _resumeAfterDrag = false;
                    },
                  ),
                ),
              ),
              IconButton(tooltip: 'Forward a bar', onPressed: _forward, icon: const Icon(Icons.fast_forward_rounded)),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep playing when I miss', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(switch ((keepPlaying, _learning)) {
                (true, true) => 'Every note you play moves on: wrong ones turn red.',
                (true, false) => 'No going back: missed notes just turn red.',
                (false, true) => 'Learn waits until you play each note right.',
                (false, false) => 'After three misses in a row, it goes back about 10 seconds.',
              }),
              value: keepPlaying,
              onChanged: (v) => context.read<ProgressStore>().keepPlaying = v,
            ),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_notice!, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            Center(
              child: Text(
                _learning
                    ? (_learn.done ? 'All played! Pick a speed, or go back to play it again.' : 'Play the lit note: the tab waits for you.')
                    : 'Play along: notes turn green when you get them, red when missed.',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: _learning ? FontWeight.w700 : FontWeight.w400, color: _learning ? null : kMuted),
              ),
            ),
            // Listening while it plays (to judge the notes) and in Learn; not while stopped.
            if (_learning || _playing || _rendering) ...[
              const SizedBox(height: 8),
              FrameListener(onFrame: _hear),
              ListeningBadge(message: _heard),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Play the tune with me', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Use headphones, so Guitaro hears only you. Off: just clicks to keep time.'),
              value: _tune,
              onChanged: _playing ? null : (v) => setState(() => _tune = v),
            ),
            const SizedBox(height: 14),
            if (last > 0)
              Row(
                children: [
                  const SizedBox(width: 64, child: Text('Section', style: TextStyle(fontWeight: FontWeight.w700))),
                  Expanded(
                    child: RangeSlider(
                      values: _loop,
                      min: 0,
                      max: last.toDouble(),
                      divisions: last,
                      labels: RangeLabels('Note ${_from + 1}', 'Note ${_to + 1}'),
                      onChanged: _playing ? null : (v) => setState(() => _loop = v),
                    ),
                  ),
                  SizedBox(width: 64, child: Text('${_from + 1}–${_to + 1}', textAlign: TextAlign.end)),
                ],
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilterChip(
                  avatar: const Icon(Icons.repeat_rounded, size: 18),
                  label: const Text('Loop'),
                  selected: _looping,
                  onSelected: (v) => setState(() => _looping = v),
                ),
                FilterChip(
                  avatar: const Icon(Icons.fiber_manual_record_rounded, size: 18, color: kMiss),
                  label: const Text('Record me'),
                  tooltip: 'Keep a recording of the run, to listen back to in Recordings.',
                  selected: _record,
                  onSelected: (v) => setState(() => _record = v),
                ),
                FilterChip(
                  avatar: const Icon(Icons.trending_up_rounded, size: 18),
                  label: const Text('Speed up when I get it right'),
                  tooltip: 'While looping: after a clean pass, 5% faster.',
                  selected: _speedUp,
                  onSelected: (v) => setState(() => _speedUp = v),
                ),
                FilterChip(
                  label: const Text('Count-in'),
                  selected: _countIn,
                  onSelected: _playing ? null : (v) => setState(() => _countIn = v),
                ),
                FilterChip(
                  avatar: const Icon(Icons.timer_outlined, size: 18),
                  label: const Text('Metronome'),
                  selected: _metronome,
                  onSelected: _playing ? null : (v) => setState(() => _metronome = v),
                ),
              ],
            ),
            if (_looping && _passes > 1)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('Loop ${_passes - 1} done', style: const TextStyle(color: kMuted)),
              ),
            const SizedBox(height: 14),
            Text('${widget.bpm} BPM at Normal · ${_learning ? 'Learn waits for each note' : '$_bpm BPM now'}',
                style: const TextStyle(color: kMuted, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
