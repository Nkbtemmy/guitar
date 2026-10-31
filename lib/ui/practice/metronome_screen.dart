import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../practice/metronome.dart';
import '../theme.dart';

/// A metronome with tap tempo, and a speed trainer: start slow, step up a few BPM every few bars
/// to a goal, the way a piece is brought up to tempo.
class MetronomeScreen extends StatefulWidget {
  const MetronomeScreen({super.key});

  @override
  State<MetronomeScreen> createState() => _MetronomeScreenState();
}

class _MetronomeScreenState extends State<MetronomeScreen> with SingleTickerProviderStateMixin {
  late final AppServices _services = context.read<AppServices>();
  late final Ticker _ticker = createTicker(_tick);
  final _clock = Stopwatch();
  final _taps = TapTempo();
  final _tapClock = Stopwatch()..start();

  int _bpm = 80, _beatsPerBar = 4;
  bool _trainer = false;
  int _goal = 120, _step = 5, _barsPerStep = 4;

  MetronomePlan? _plan;
  ({int bar, int bpm, int beat})? _now;
  bool _starting = false;

  /// Changing the tempo quickly starts several runs: only the latest may take over.
  int _requests = 0;

  bool get _running => _plan != null;

  MetronomePlan _newPlan() => _trainer && _goal > _bpm
      ? MetronomePlan.trainer(from: _bpm, to: _goal, step: _step, barsPerStep: _barsPerStep, beatsPerBar: _beatsPerBar)
      : MetronomePlan.steady(bpm: _bpm, beatsPerBar: _beatsPerBar);

  Future<void> _start([MetronomePlan? plan]) async {
    final next = plan ?? _newPlan();
    final request = ++_requests;
    setState(() => _starting = true);
    await _services.player.playMetronome(barBpms: next.bars, beatsPerBar: next.beatsPerBar);
    if (!mounted || request != _requests) return;
    _clock
      ..reset()
      ..start();
    setState(() {
      _plan = next;
      _starting = false;
    });
    if (!_ticker.isActive) _ticker.start();
  }

  void _stop() {
    _requests++;
    _clock.stop();
    _ticker.stop();
    _services.player.stop();
    setState(() {
      _plan = null;
      _now = null;
    });
  }

  /// A setting changed while it plays: start again with it.
  void _restart() {
    if (_running) _start();
  }

  void _tick(Duration _) {
    final plan = _plan;
    if (plan == null) return;
    final t = _clock.elapsedMicroseconds / 1e6;
    if (t >= plan.seconds) {
      // A long steady run, or the trainer's hold at its goal, carries on at the tempo it ended on.
      _start(MetronomePlan.steady(bpm: plan.bars.last, beatsPerBar: _beatsPerBar));
      return;
    }
    final now = plan.at(t);
    if (now != _now) setState(() => _now = now);
  }

  void _setBpm(int bpm) {
    setState(() => _bpm = bpm.clamp(30, 260));
    _restart();
  }

  void _tap() {
    final bpm = _taps.tap(_tapClock.elapsed);
    if (bpm != null) _setBpm(bpm);
  }

  @override
  void dispose() {
    _clock.stop();
    _services.player.stop();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = _now;
    final shown = now?.bpm ?? _bpm;
    return Scaffold(
      appBar: AppBar(title: const Text('Metronome')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Center(child: Text('$shown', style: const TextStyle(fontSize: 88, fontWeight: FontWeight.w900, height: 1))),
          const Center(child: Text('BPM', style: TextStyle(color: kMuted, fontWeight: FontWeight.w800, letterSpacing: 2))),
          const SizedBox(height: 18),
          // The beats of the bar, the one playing lit; the first is the accent.
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var b = 0; b < _beatsPerBar; b++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 60),
                margin: const EdgeInsets.symmetric(horizontal: 6),
                width: b == 0 ? 26 : 20,
                height: b == 0 ? 26 : 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: now != null && now.beat == b ? (b == 0 ? kAccent : kAccentSoft) : kSurfaceHigh,
                ),
              ),
          ]),
          if (_trainer && now != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(now.bpm >= _goal ? 'At your goal: hold it there.' : 'Speeding up to $_goal…',
                  textAlign: TextAlign.center, style: const TextStyle(color: kMuted)),
            ),
          const SizedBox(height: 18),
          Row(children: [
            IconButton.outlined(tooltip: 'Slower', onPressed: () => _setBpm(_bpm - 1), icon: const Icon(Icons.remove_rounded)),
            Expanded(
              child: Slider(
                value: _bpm.toDouble().clamp(30, 260),
                min: 30,
                max: 260,
                onChanged: (v) => setState(() => _bpm = v.round()),
                onChangeEnd: (_) => _restart(),
              ),
            ),
            IconButton.outlined(tooltip: 'Faster', onPressed: () => _setBpm(_bpm + 1), icon: const Icon(Icons.add_rounded)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 2, label: Text('2/4')),
                  ButtonSegment(value: 3, label: Text('3/4')),
                  ButtonSegment(value: 4, label: Text('4/4')),
                  ButtonSegment(value: 6, label: Text('6/8')),
                ],
                selected: {_beatsPerBar},
                onSelectionChanged: (v) {
                  setState(() => _beatsPerBar = v.first);
                  _restart();
                },
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(onPressed: _tap, child: const Text('Tap')),
          ]),
          const SizedBox(height: 16),
          Card(
            child: Column(children: [
              SwitchListTile(
                title: const Text('Speed trainer', style: TextStyle(fontWeight: FontWeight.w800)),
                subtitle: const Text('Start slow and speed up step by step, the way to get a song up to tempo.'),
                value: _trainer,
                onChanged: (v) {
                  setState(() => _trainer = v);
                  _restart();
                },
              ),
              if (_trainer) ...[
                _Stepper(label: 'Goal', value: '$_goal BPM', onLess: () => _setGoal(_goal - 5), onMore: () => _setGoal(_goal + 5)),
                _Stepper(label: 'Faster by', value: '$_step BPM', onLess: () => _setStep(_step - 1), onMore: () => _setStep(_step + 1)),
                _Stepper(
                  label: 'Every',
                  value: '$_barsPerStep bars',
                  onLess: () => _setBarsPerStep(_barsPerStep - 1),
                  onMore: () => _setBarsPerStep(_barsPerStep + 1),
                ),
                const SizedBox(height: 8),
              ],
            ]),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _starting ? null : (_running ? _stop : _start),
            icon: Icon(_running ? Icons.stop_rounded : Icons.play_arrow_rounded),
            label: Text(_running ? 'Stop' : 'Start'),
          ),
        ]),
      ),
    );
  }

  void _setGoal(int v) {
    setState(() => _goal = v.clamp(40, 260));
    _restart();
  }

  void _setStep(int v) {
    setState(() => _step = v.clamp(1, 20));
    _restart();
  }

  void _setBarsPerStep(int v) {
    setState(() => _barsPerStep = v.clamp(1, 16));
    _restart();
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.label, required this.value, required this.onLess, required this.onMore});

  final String label, value;
  final VoidCallback onLess, onMore;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        child: Row(children: [
          SizedBox(width: 84, child: Text(label, style: const TextStyle(color: kMuted))),
          IconButton(tooltip: 'Less', onPressed: onLess, icon: const Icon(Icons.remove_circle_outline_rounded)),
          Expanded(child: Text(value, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800))),
          IconButton(tooltip: 'More', onPressed: onMore, icon: const Icon(Icons.add_circle_outline_rounded)),
        ]),
      );
}
