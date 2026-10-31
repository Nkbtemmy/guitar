import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../audio/mic_listener.dart';
import '../../practice/takes.dart';
import '../../progress/practice_log.dart';
import '../theme.dart';
import '../widgets/listening.dart';

String _clock(double seconds) => '${seconds ~/ 60}:${(seconds % 60).floor().toString().padLeft(2, '0')}';

String _when(DateTime t) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${t.day} ${months[t.month - 1]}, ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// The learner's recordings: record yourself practising, listen back, keep the best (star them).
/// Takes from play-along ("Record me") show up here too. Everything stays on the phone.
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key});

  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> with SingleTickerProviderStateMixin {
  late final MicListener _mic = context.read<MicListener>();
  late final PracticeLog _log = context.read<PracticeLog>();
  late final Ticker _ticker = createTicker((elapsed) {
    if (elapsed.inSeconds != _elapsed.inSeconds) setState(() => _elapsed = elapsed);
  });
  String? _recording;
  Duration _elapsed = Duration.zero;

  AudioPlayer? _player;
  StreamSubscription<void>? _done;
  String? _playing;

  Future<void> _record() async {
    final id = await Takes.start(_mic);
    if (!mounted) return;
    setState(() {
      _recording = id;
      _elapsed = Duration.zero;
    });
    _ticker.start();
  }

  Future<void> _stopRecording() async {
    final id = _recording;
    if (id == null) return;
    _ticker.stop();
    setState(() => _recording = null);
    final take = await Takes.finish(_mic, _log, id, title: 'Practice, ${_when(DateTime.now())}');
    if (take == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Too short to keep.')));
    }
  }

  Future<void> _togglePlay(Take take) async {
    final player = _player ??= AudioPlayer();
    _done ??= player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = null);
    });
    try {
      await player.stop();
      if (_playing == take.id) {
        setState(() => _playing = null);
        return;
      }
      setState(() => _playing = take.id);
      await player.play(DeviceFileSource((await Takes.fileOf(take.id)).path, mimeType: 'audio/wav'));
    } on Exception catch (e) {
      debugPrint('Recordings: could not play ${take.id}: $e');
      if (mounted) setState(() => _playing = null);
    }
  }

  Future<void> _rename(Take take) async {
    final name = await showDialog<String>(context: context, builder: (_) => _NameDialog(name: take.title));
    if (name == null || name.trim().isEmpty) return;
    take.title = name.trim();
    _log.updateTake(take);
  }

  Future<void> _delete(Take take) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this recording?'),
        content: Text(take.title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    if (_playing == take.id) await _player?.stop();
    await Takes.delete(_log, take);
  }

  @override
  void dispose() {
    _ticker.dispose();
    if (_recording case final id?) Takes.finish(_mic, _log, id, title: 'Practice, ${_when(DateTime.now())}');
    _done?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final takes = context.watch<PracticeLog>().takes;
    final recording = _recording != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Recordings')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                if (recording) ...[
                  FrameListener(onFrame: (_) {}),
                  Text(_clock(_elapsed.inSeconds.toDouble()), style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 8),
                  ListenableBuilder(
                    listenable: _mic,
                    builder: (context, _) => ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(value: _mic.level, minHeight: 10, color: kMiss, backgroundColor: kSurfaceHigh),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: recording ? kMiss : null),
                  onPressed: recording ? _stopRecording : _record,
                  icon: Icon(recording ? Icons.stop_rounded : Icons.fiber_manual_record_rounded),
                  label: Text(recording ? 'Stop and keep' : 'Record me playing'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Hear yourself the way a listener does. Recordings stay on this phone. In play-along, '
                  'turn on "Record me" to keep a run with the song.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kMuted, fontSize: 13),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          if (takes.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No recordings yet.', textAlign: TextAlign.center, style: TextStyle(color: kMuted)),
            ),
          for (final take in takes)
            Card(
              margin: const EdgeInsets.only(top: 8),
              child: ListTile(
                leading: IconButton.filledTonal(
                  tooltip: _playing == take.id ? 'Stop' : 'Play',
                  onPressed: () => _togglePlay(take),
                  icon: Icon(_playing == take.id ? Icons.stop_rounded : Icons.play_arrow_rounded),
                ),
                title: Row(children: [
                  Flexible(child: Text(take.title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
                  if (take.favourite) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.star_rounded, size: 18, color: kAccent)),
                ]),
                subtitle: Text([_when(take.created), _clock(take.seconds), if (take.note.isNotEmpty) take.note].join(' · ')),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) {
                    switch (v) {
                      case 'star':
                        take.favourite = !take.favourite;
                        _log.updateTake(take);
                      case 'rename':
                        _rename(take);
                      default:
                        _delete(take);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'star', child: Text(take.favourite ? 'Unstar' : 'Star as a keeper')),
                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Asks for a recording's name. It owns its text field's controller, which outlives the dialog's
/// closing animation.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.name});

  final String name;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.name);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Name this recording'),
        content: TextField(controller: _controller, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, _controller.text), child: const Text('Save')),
        ],
      );
}
