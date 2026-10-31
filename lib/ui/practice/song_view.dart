import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../audio/analysis.dart';
import '../../audio/chord_matcher.dart';
import '../../curriculum/models.dart';
import '../../music/chord.dart';
import '../../practice/takes.dart';
import '../../practice/trackers.dart';
import '../../progress/practice_log.dart';
import '../../progress/progress_store.dart';
import '../../sheets/chord_resolver.dart';
import '../lesson/steps.dart';
import '../theme.dart';
import '../widgets/chord_view.dart';
import '../widgets/listening.dart';
import '../widgets/listening_badge.dart';
import '../widgets/tab_highway.dart';
import '../widgets/tab_staff.dart';
import 'play_along.dart';

enum SongMode { wait, playAlong }

/// Plays through a song chart. Wait mode advances only when the right chord is strummed;
/// play-along keeps time with the metronome (and, optionally, the song strummed along) and
/// scores each bar.
///
/// Either way the learner can go back: tap a bar to start (or jump) there, "Back" returns to the
/// start of the line being played, and "Repeat this line" loops it until they stop. In
/// play-along each bar turns green or red as it's judged, and after two missed in a row the song
/// goes back about ten seconds and carries on from there (see [Rewinder]).
class SongView extends StatefulWidget {
  const SongView({
    super.key,
    required this.song,
    this.onDone,
    this.showHeader = true,
    this.chordFor,
    this.capo = 0,
    this.place,
    this.startBar = 0,
    this.repeat = false,
  });

  final Song song;
  final StepDone? onDone;
  final bool showHeader;

  /// Looks up a bar's chord; defaults to the chord library. Song sheets use any chord name.
  final Chord Function(String id)? chordFor;

  /// The capo the learner plays with: shapes are shown as written and heard this many frets up.
  final int capo;

  /// Where this song lives, so the lines the learner keeps missing are kept as weak spots to
  /// practise (none for a song that can't be found again).
  final SpotPlace? place;

  /// Open in play-along at [startBar], looping its line when [repeat] (practising a weak spot).
  final int startBar;
  final bool repeat;

  @override
  State<SongView> createState() => _SongViewState();
}

class _SongViewState extends State<SongView> with Listening, SingleTickerProviderStateMixin {
  late final AppServices _services = context.read<AppServices>();
  late final List<Chord> _bars = [for (final id in widget.song.bars) _chord(id)];

  /// What each bar sounds like on the learner's guitar (the shape moved up by the capo).
  late final List<Chord> _heard = [for (final c in _bars) c.withCapo(widget.capo)];
  late final _lines = SongLines([for (final line in widget.song.lines) line.bars.length]);
  late final Ticker _ticker = createTicker(_tick);
  late SongMode _mode = widget.repeat || widget.startBar > 0 ? SongMode.playAlong : SongMode.wait;
  bool _showTab = false;
  // On in the songbook; off in lessons, where the mic must hear only the learner to give stars.
  late bool _backing = widget.onDone == null;
  double _tempo = 0.8;
  ChordVerdict? _verdict;
  late SequenceTracker<Chord> _wait = _newTracker();
  PlayAlongSession? _session;
  String? _result;
  late final _lineKeys = [for (final _ in widget.song.lines) GlobalKey()];
  int _followedLine = -1;

  /// Where the next play-along starts (tap a bar to choose it).
  // A weak spot from a song edited since may point past its end.
  late int _startBar = widget.startBar.clamp(0, math.max(0, _bars.length - 1));

  /// Play the line holding [_startBar] over and over, until stopped.
  late bool _repeat = widget.repeat;
  int _passes = 0;

  /// The bars the running play-along covers: [_from, _to).
  int _from = 0, _to = 0;

  /// Goes back about ten seconds when the learner keeps missing, unless Keep playing is on.
  final _rewinder = Rewinder();

  /// With Repeat: after a clean time through, play the next one a little faster.
  bool _speedUp = false;

  /// Record the run, song and all, as a take ([_take] while it records, and where it's kept).
  bool _record = false;
  ({String id, PracticeLog log})? _take;

  /// Ends the take being recorded and keeps it, with how the run went.
  void _finishTake([String note = '']) {
    final take = _take;
    if (take == null) return;
    _take = null;
    Takes.finish(mic, take.log, take.id, title: widget.song.title, note: note);
  }

  /// Bars of the running session judged so far; where this run began (going back doesn't start a
  /// new run), and how many times it went back.
  int _judged = 0, _runStart = 0, _rewinds = 0;

  /// How each bar went the last time it was played: right, missed, or null (not played yet).
  late final List<bool?> _marks = List.filled(_bars.length, null);

  /// The song as a highway: each bar's chord where the bar starts, named where it changes, and
  /// its strums underneath. [_beat] is where the song is.
  late final int _beatsPerBar = widget.song.beatsPerBar;
  late final StrumPattern _pattern = widget.song.strumPattern;
  late final List<HighwayNote> _highway = [for (var i = 0; i < _bars.length; i++) _highwayNote(i)];
  late final List<HighwayStrum> _strums = [
    for (var i = 0; i < _bars.length; i++)
      for (final hit in _pattern.hits)
        HighwayStrum(i * _beatsPerBar + _pattern.beatOf(hit.slot),
            down: hit.direction == StrumDirection.down, muted: hit.muted, accent: hit.accent),
  ];
  late final List<double> _barBeats = [for (var i = 1; i < _bars.length; i++) (i * _beatsPerBar).toDouble()];
  final _beat = ValueNotifier<double>(0);

  /// Each line's lyrics, by the bar it starts on: how a weak spot is named.
  late final Map<int, String> _lyricsAt = () {
    final at = <int, String>{};
    var bar = 0;
    for (final line in widget.song.lines) {
      if (line.bars.isEmpty) continue;
      at[bar] = line.lyrics;
      bar += line.bars.length;
    }
    return at;
  }();

  HighwayNote _highwayNote(int bar) {
    final column = TabColumn.chord(_bars[bar], label: false);
    return HighwayNote((bar * _beatsPerBar).toDouble(), column.frets,
        muted: column.muted, label: bar == 0 || _bars[bar].id != _bars[bar - 1].id ? _bars[bar].symbol : null);
  }

  Chord _chord(String id) => widget.chordFor?.call(id) ?? _services.library.byId(id);

  SequenceTracker<Chord> _newTracker() =>
      SequenceTracker<Chord>(targets: _heard, matcher: (f, c) => _verdict?.matches ?? false);

  int get _currentBar {
    if (_mode == SongMode.wait) return _wait.index;
    final bar = _session?.currentBar ?? -1;
    return bar < 0 ? -1 : _from + bar;
  }

  @override
  void onFrame(AnalysisFrame f) {
    if (_mode == SongMode.playAlong) {
      _session?.onFrame(f);
      return;
    }
    final target = _wait.current;
    if (target == null) return;
    _verdict = f.hasSound ? _services.matcher.verify(f.peaks, target) : null;
    final bar = _wait.index;
    if (_wait.process(f)) {
      setState(() => _marks[bar] = true);
      if (_wait.done) {
        // Only a song played bar by bar counts: jumping ahead skips the bars in between.
        final all = !_marks.contains(null);
        _finish(all ? 0.85 : null,
            all ? 'Song complete! Try play-along mode for 3 stars.' : 'You reached the end! Play every bar to finish the song.');
      }
    }
  }

  /// Shows [message], and reports [score] to the lesson when there is one to give.
  void _finish(double? score, String message) {
    setState(() => _result = message);
    if (score != null) widget.onDone?.call(score);
  }

  void _setMode(SongMode mode) {
    _session?.stop();
    _ticker.stop();
    setState(() {
      _mode = mode;
      _session = null;
      _result = null;
      _wait = _newTracker();
      _marks.fillRange(0, _marks.length, null);
      _startBar = 0;
      _passes = 0;
    });
  }

  /// Tapping a bar: in wait mode, jump there; in play-along, start from there (right away, if
  /// the song is already playing).
  void _tapBar(int bar) {
    if (_mode == SongMode.wait) {
      setState(() {
        _wait.jumpTo(bar);
        _result = null;
      });
      return;
    }
    if (_session != null) {
      _restartAt(bar);
    } else {
      setState(() => _startBar = bar);
    }
  }

  /// Starts playing along; [resume] carries on the same run after going back.
  Future<void> _startPlayAlong({bool resume = false}) async {
    final from = _repeat ? _lines.startOf(_startBar) : _startBar;
    final to = _repeat ? _lines.endOf(_startBar) : _bars.length;
    final session = PlayAlongSession(
      player: _services.player,
      matcher: _services.matcher,
      bpm: (widget.song.bpm * _tempo).round(),
      beatsPerBar: widget.song.beatsPerBar,
      barChords: _heard.sublist(from, to),
      backing: _backing ? (key: '${widget.song.id}@${widget.capo}:$from-$to', strum: widget.song.strumPattern) : null,
    );
    // A take runs from the first start to the end of the run, going back and repeats included.
    if (_record && _take == null) {
      final log = context.read<PracticeLog>();
      final id = await Takes.start(mic);
      if (!mounted) return;
      _take = (id: id, log: log);
    }
    setState(() {
      _session = session;
      _from = from;
      _to = to;
      _judged = 0;
      if (!resume) {
        _runStart = from;
        _rewinds = 0;
        _rewinder.reset();
        if (!_repeat) _result = null;
      }
    });
    // While the track renders, the highway waits at the count-in, a bar before the first bar.
    _beat.value = ((from - 1) * _beatsPerBar).toDouble();
    await session.start();
    // The track renders first: the screen may have closed, or moved on, in the meantime.
    if (!mounted || _session != session) return;
    if (!_ticker.isActive) _ticker.start();
  }

  /// Keeps the results of the bars the session got through.
  void _keepMarks(PlayAlongSession s, {required int upTo}) {
    for (var i = 0; i < upTo && i < s.barChords.length; i++) {
      _marks[_from + i] = s.bars.barCorrect(i);
    }
  }

  /// Ends the run; Start then picks up at the start of the line it stopped in.
  void _stop() {
    final s = _session;
    if (s == null) return;
    final bar = _currentBar;
    _keepMarks(s, upTo: s.currentBar < 0 ? 0 : s.currentBar);
    s.stop();
    _ticker.stop();
    _finishTake();
    setState(() {
      _session = null;
      _passes = 0;
      _result = null;
      if (bar >= 0) _startBar = _lines.startOf(bar);
    });
  }

  /// Plays from [bar]: a new run, or the same one when the song went back by itself ([auto]).
  void _restartAt(int bar, {bool auto = false}) {
    final s = _session;
    if (s != null) {
      _keepMarks(s, upTo: s.currentBar < 0 ? 0 : s.currentBar);
      s.stop();
    }
    _startBar = bar;
    _startPlayAlong(resume: auto);
  }

  /// Counts [bar] towards its line's weak spot.
  void _remember(int bar, bool right) {
    final place = widget.place;
    if (place == null) return;
    final start = _lines.startOf(bar), end = _lines.endOf(bar);
    final words = _lyricsAt[start] ?? '';
    context.read<PracticeLog>().recordSpot(place,
        from: start,
        to: end,
        title: widget.song.title,
        detail: 'Bars ${start + 1}–$end${words.isEmpty ? '' : ': "$words"'}',
        right: right);
  }

  /// Judges each bar of [s] a moment after it ends (the mic runs a little behind). True when the
  /// learner kept missing and the song has gone back.
  bool _judge(PlayAlongSession s) {
    while (_judged < s.barChords.length && s.seconds >= s.bars.startSeconds + (_judged + 1) * s.bars.barSeconds + 0.3) {
      final bar = _from + _judged;
      final right = s.bars.barCorrect(_judged++);
      _marks[bar] = right;
      _remember(bar, right);
      if (context.read<ProgressStore>().keepPlaying || _repeat || !_rewinder.record(right)) continue;
      // About ten seconds back, from the start of a line, but not before this run began.
      final back = math.max(_runStart, _lines.startOf(bar + 1 - (Rewinder.seconds / s.bars.barSeconds).ceil()));
      if (!_rewinder.back(back)) continue;
      _rewinds++;
      _result = 'Missed a couple of bars: back to bar ${back + 1}. Keep going!';
      _restartAt(back, auto: true);
      return true;
    }
    return false;
  }

  /// Back to the start of the line being played, or the line before if it has only just begun.
  void _back() {
    final s = _session;
    if (s == null) return;
    final bar = _currentBar;
    _restartAt(bar >= 0 ? _lines.back(bar, s.barProgress) : _lines.back(_from, 0));
  }

  void _setRepeat(bool on) {
    setState(() {
      _repeat = on;
      _passes = 0;
    });
    // Turned on mid-song: loop the line being played, from its start.
    if (on && _session != null) {
      final bar = _currentBar;
      _restartAt(bar >= 0 ? bar : _from);
    }
  }

  /// Loops the first line with a missed bar.
  void _practiseMissed() {
    final missed = _marks.indexOf(false);
    if (missed < 0) return;
    setState(() {
      _repeat = true;
      _passes = 0;
      _startBar = missed;
    });
    _startPlayAlong();
  }

  void _tick(Duration _) {
    final s = _session;
    if (s == null) return;
    if (_judge(s)) return;
    if (s.finished) {
      s.stop();
      _ticker.stop();
      _keepMarks(s, upTo: s.barChords.length);
      if (_repeat) {
        final right = [for (var i = 0; i < s.barChords.length; i++) s.bars.barCorrect(i)].where((ok) => ok).length;
        _passes++;
        var message = 'Time $_passes: $right of ${s.barChords.length} bars right. Again!';
        if (_speedUp && right >= 0.9 * s.barChords.length && _tempo < 1) {
          _tempo = math.min(1.0, _tempo + 0.05);
          message = 'Clean! Speeding up to ${(_tempo * 100).round()}%: ${(widget.song.bpm * _tempo).round()} BPM.';
        }
        setState(() => _result = message);
        _startPlayAlong();
        return;
      }
      setState(() => _session = null);
      final right = _marks.sublist(_runStart, _to).where((m) => m == true).length;
      _finishTake('$right of ${_to - _runStart} bars right');
      final wentBack = _rewinds == 0 ? '' : ', going back $_rewinds time${_rewinds == 1 ? '' : 's'}';
      if (_runStart == 0 && _to == _bars.length) {
        // Each bar as it went the last time it was played. Full marks need full tempo; slower
        // practice tops out at two stars.
        final accuracy = right / _bars.length;
        final score = _tempo >= 1.0 ? accuracy : accuracy * 0.85;
        _finish(score,
            'You played ${(accuracy * 100).round()}% of the bars right${_tempo < 1 ? ' at ${(_tempo * 100).round()}% speed' : ''}$wentBack.');
      } else {
        // Part of the song is practice: it doesn't count towards the lesson.
        _finish(null, 'Bars ${_runStart + 1}–$_to: you played $right of ${_to - _runStart} right$wentBack.');
      }
      return;
    }
    // The highway moves every frame (it repaints by itself, nothing rebuilds); the count-in bar
    // comes before the first bar played.
    _beat.value = (_from - 1) * _beatsPerBar + s.seconds / s.beatSeconds;
    // The chart only shows the bar and the count-in, which change a few times a second:
    // rebuilding it on every frame redrew the whole song 60 times a second.
    final shown = (s.currentBar, s.countIn);
    if (shown == _shown) return;
    _shown = shown;
    setState(() {});
  }

  (int, int)? _shown;

  /// How bar [i] went: right, missed, or null (not played, or still to come in this run).
  bool? _markOf(int i) {
    final s = _session;
    if (s != null && i >= _from && i < _to) {
      final local = i - _from;
      return s.currentBar >= 0 && local < s.currentBar ? s.bars.barCorrect(local) : null;
    }
    return _marks[i];
  }

  @override
  void dispose() {
    _session?.stop();
    _finishTake();
    _ticker.dispose();
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final bar = _currentBar;
    final current = bar >= 0 && bar < _bars.length ? _bars[bar] : null;
    // Preview the next chord *change*, not a repeat of the current chord.
    final next = current == null ? null : _bars.skip(bar + 1).where((c) => c.id != current.id).firstOrNull;
    final s = _session;
    final playAlong = _mode == SongMode.playAlong;
    _follow(bar, playing: s != null || _wait.index > 0);
    // Stopped, the highway waits where the next run starts.
    if (s == null) _beat.value = ((playAlong ? _startBar : _wait.index) * _beatsPerBar).toDouble();
    // The bars the next (or current) run covers, shaded on the chart when it isn't the whole song.
    final (int, int) range = s != null
        ? (_from, _to)
        : _repeat
            ? (_lines.startOf(_startBar), _lines.endOf(_startBar))
            : (_startBar, _bars.length);
    final partial = playAlong && (range.$1 > 0 || range.$2 < _bars.length);
    var barIndex = 0;
    var lineIndex = 0;
    // What's playing stays at the top; the settings, the chart and the lyrics scroll under it.
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.showHeader) ...[
            Text(song.title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
            Text('${song.credit} · ${song.beatsPerBar}/4 · ${song.bpm} BPM · ${song.chordIds.map((c) => _chord(c).symbol).join(' ')}',
                style: const TextStyle(color: kMuted)),
            const SizedBox(height: 12),
          ],
          SegmentedButton<SongMode>(
            segments: const [
              ButtonSegment(value: SongMode.wait, icon: Icon(Icons.hourglass_bottom_rounded), label: Text('Wait mode')),
              ButtonSegment(value: SongMode.playAlong, icon: Icon(Icons.speed_rounded), label: Text('Play along')),
            ],
            selected: {_mode},
            onSelectionChanged: (v) => _setMode(v.first),
          ),
          const SizedBox(height: 12),
          if (playAlong)
            Stack(children: [
              TabHighway(
                notes: _highway,
                strums: _strums,
                bars: _barBeats,
                results: [for (var i = 0; i < _bars.length; i++) _markOf(i)],
                position: _beat,
                height: 190,
                beatWidth: 46,
              ),
              if (s != null && s.countIn > 0)
                Positioned(
                  left: 12,
                  top: 0,
                  child: Text('${s.countIn}', style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: kAccent)),
                ),
            ])
          else
            SizedBox(
              height: 170,
              child: current == null
                  ? Center(
                      child: Text(_result ?? 'Done!',
                          textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)))
                  : Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      ChordView(chord: current, width: 110),
                      if (next != null) ...[
                        const SizedBox(width: 18),
                        Opacity(opacity: 0.5, child: ChordView(chord: next, width: 60, compact: true)),
                      ],
                    ]),
            ),
          if (playAlong && s != null) ...[
            const SizedBox(height: 8),
            // Going back while playing: the way to try a hard part again without starting over.
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(onPressed: _back, icon: const Icon(Icons.replay_rounded), label: const Text('Back')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(onPressed: _stop, icon: const Icon(Icons.stop_rounded), label: const Text('Stop')),
              ),
              const SizedBox(width: 8),
              FilterChip(
                avatar: const Icon(Icons.repeat_rounded, size: 18),
                label: const Text('Repeat'),
                selected: _repeat,
                onSelected: _setRepeat,
              ),
            ]),
          ],
          if (_result != null && (playAlong || current != null))
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(_result!, textAlign: TextAlign.center)),
        ]),
      ),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (playAlong && s == null) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Play the song with me', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('Guitaro strums along while you play. Use headphones so it only hears you.'),
                value: _backing,
                onChanged: (v) => setState(() => _backing = v),
              ),
              Builder(builder: (context) {
                final keepPlaying = context.select<ProgressStore, bool>((p) => p.keepPlaying);
                return SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Keep playing when I miss', style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(keepPlaying
                      ? 'No going back: missed bars just turn red.'
                      : 'After two missed bars in a row, Guitaro goes back about 10 seconds and carries on.'),
                  value: keepPlaying,
                  onChanged: (v) => context.read<ProgressStore>().keepPlaying = v,
                );
              }),
              Row(children: [
                const Text('Tempo', style: TextStyle(color: kMuted)),
                Expanded(
                  child: Slider(
                    value: _tempo,
                    min: 0.5,
                    max: 1.0,
                    divisions: 10,
                    label: '${(song.bpm * _tempo).round()} BPM',
                    onChanged: (v) => setState(() => _tempo = v),
                  ),
                ),
                Text('${(song.bpm * _tempo).round()} BPM'),
              ]),
              FilledButton.icon(
                onPressed: _startPlayAlong,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(_repeat
                    ? 'Start: repeat bars ${range.$1 + 1}–${range.$2}'
                    : _startBar > 0
                        ? 'Start from bar ${_startBar + 1}'
                        : (_result == null ? 'Start' : 'Play again')),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                FilterChip(
                  avatar: const Icon(Icons.repeat_rounded, size: 18),
                  label: const Text('Repeat this line'),
                  selected: _repeat,
                  onSelected: _setRepeat,
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
                  tooltip: 'With Repeat on: after a clean time through, 5% faster, up to full speed.',
                  selected: _speedUp,
                  onSelected: (v) => setState(() => _speedUp = v),
                ),
                if (_startBar > 0)
                  ActionChip(
                    avatar: const Icon(Icons.first_page_rounded, size: 18),
                    label: const Text('From the top'),
                    onPressed: () => setState(() => _startBar = 0),
                  ),
                if (_marks.contains(false))
                  ActionChip(
                    avatar: const Icon(Icons.healing_rounded, size: 18),
                    label: const Text('Practise where I went wrong'),
                    onPressed: _practiseMissed,
                  ),
              ]),
            ],
            if (_mode == SongMode.wait && !_wait.done && _wait.index > 0)
              Center(
                child: TextButton.icon(
                  onPressed: () => _tapBar(_wait.index - 1),
                  icon: const Icon(Icons.undo_rounded),
                  label: const Text('Back a chord'),
                ),
              ),
            if (_mode == SongMode.wait && _wait.done)
              OutlinedButton.icon(
                  onPressed: () => _setMode(SongMode.wait), icon: const Icon(Icons.replay_rounded), label: const Text('Play again')),
            const SizedBox(height: 10),
            if (s == null)
              Center(
                child: HearButton(
                  label: 'Listen to the song',
                  onPressed: () => _services.player.playChords(
                    key: '${song.id}@${widget.capo}',
                    bars: _heard,
                    strum: song.strumPattern,
                    bpm: (song.bpm * _tempo).round(),
                  ),
                ),
              ),
            const SizedBox(height: 14),
            ListeningBadge(message: _mode == SongMode.wait ? 'Waiting for ${current?.symbol ?? '…'}' : null),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: Text(playAlong ? 'Tap a bar to start from there.' : 'Tap a bar to jump there.',
                    style: const TextStyle(color: kMuted, fontSize: 13)),
              ),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: false, icon: Icon(Icons.view_module_rounded, size: 18), label: Text('Chart')),
                  ButtonSegment(value: true, icon: Icon(Icons.table_rows_rounded, size: 18), label: Text('Tab')),
                ],
                selected: {_showTab},
                onSelectionChanged: (v) => setState(() => _showTab = v.first),
              ),
            ]),
            const SizedBox(height: 8),
            for (final line in song.lines) ...[
              SizedBox(key: _lineKeys[lineIndex++], height: 0),
              if (_showTab)
                Builder(builder: (context) {
                  final start = barIndex;
                  barIndex += line.bars.length;
                  final inRange = partial && range.$1 < barIndex && range.$2 > start;
                  return TabStaff(
                    columns: [for (final id in line.bars) TabColumn.chord(_chord(id))],
                    current: bar >= start && bar < barIndex ? bar - start : (bar >= barIndex ? line.bars.length : -1),
                    markDone: true,
                    expand: true,
                    lineGap: 15,
                    fontSize: 13,
                    rangeStart: inRange ? (range.$1 - start).clamp(0, line.bars.length - 1) : -1,
                    rangeEnd: inRange ? (range.$2 - 1 - start).clamp(0, line.bars.length - 1) : -1,
                    onTapColumn: (c) => _tapBar(start + c),
                  );
                })
              else
                Row(children: [
                  for (final chordId in line.bars)
                    Builder(builder: (context) {
                      final i = barIndex++;
                      return _BarCell(
                        symbol: _chord(chordId).symbol,
                        current: i == bar,
                        mark: _markOf(i),
                        start: playAlong && s == null && partial && i == range.$1,
                        inRange: partial && i >= range.$1 && i < range.$2,
                        onTap: () => _tapBar(i),
                      );
                    }),
                ]),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 12, left: 4),
                child: Text(line.lyrics.isEmpty ? '♪' : line.lyrics, style: const TextStyle(fontSize: 16, color: kTextSoft)),
              ),
            ],
          ]),
        ),
      ),
    ]);
  }

  /// Keeps the line being played in view on long songs.
  void _follow(int bar, {required bool playing}) {
    if (!playing || bar < 0) return;
    var line = 0, end = 0;
    for (; line < widget.song.lines.length; line++) {
      end += widget.song.lines[line].bars.length;
      if (bar < end) break;
    }
    if (line == _followedLine || line >= _lineKeys.length) return;
    _followedLine = line;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _lineKeys[line].currentContext;
      if (target != null && target.mounted) {
        Scrollable.ensureVisible(target, alignment: 0.3, duration: const Duration(milliseconds: 300));
      }
    });
  }
}

/// One bar of the chart: its chord, lit while it plays, then green when it was played right
/// and red when it was missed. The bar a run starts from is outlined.
class _BarCell extends StatelessWidget {
  const _BarCell({
    required this.symbol,
    required this.current,
    required this.mark,
    required this.start,
    required this.inRange,
    required this.onTap,
  });

  final String symbol;
  final bool current, start, inRange;
  final bool? mark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = current ? kOnAccent : switch (mark) { true => kSuccess, false => kMiss, null => null };
    return Expanded(
      child: Semantics(
        button: true,
        label: '$symbol${mark == false ? ', missed' : ''}',
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 44,
            margin: const EdgeInsets.only(right: 4),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: current
                  ? kAccent
                  : switch (mark) {
                      true => kSuccess.withValues(alpha: 0.15),
                      false => kMiss.withValues(alpha: 0.15),
                      null => inRange ? kAccent.withValues(alpha: 0.08) : kSurfaceHigh,
                    },
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: start ? kAccent : Colors.transparent, width: 2),
            ),
            // Long lines get narrow cells; shrink names like F#m7 rather than overflow.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(symbol, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: color)),
            ),
          ),
        ),
      ),
    );
  }
}
