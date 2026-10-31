import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../../analytics.dart';
import '../../app_services.dart';
import '../../audio/analysis.dart';
import '../../audio/playback_listener.dart';
import '../../sheets/chord_finder.dart';
import '../../sheets/songbook_store.dart';
import '../theme.dart';
import '../widgets/chord_view.dart';
import '../widgets/listening.dart';
import '../widgets/listening_badge.dart';
import 'sheet_editor.dart';

/// Plays a YouTube video in the app and writes down its chords (and melody) as it plays. On Android 10+ the
/// app listens to its own playback directly (the system asks once per session); elsewhere it
/// listens through the mic, so the phone's speaker has to be on. Chord times follow the video,
/// so a chord's timestamp is where it starts in the video.
class VideoFinderScreen extends StatefulWidget {
  const VideoFinderScreen({super.key, required this.link});

  /// A normalized YouTube watch link (see `youtubeUrl`).
  final String link;

  @override
  State<VideoFinderScreen> createState() => _VideoFinderScreenState();
}

class _VideoFinderScreenState extends State<VideoFinderScreen> {
  final _finder = ChordFinder();
  late final YoutubePlayerController _player;
  final _capture = PlaybackListener();
  bool? _captureSupported;
  StreamSubscription<AnalysisFrame>? _captured;
  StreamSubscription<YoutubeVideoState>? _videoState;
  StreamSubscription<YoutubePlayerValue>? _playerValue;

  /// Whether we're finding chords (the player may still be paused by the user).
  bool _finding = false;
  PlayerState _state = PlayerState.unknown;
  Duration _position = Duration.zero;
  DateTime _positionAt = DateTime.now();
  double _duration = 0;

  String get _videoId => Uri.parse(widget.link).queryParameters['v']!;

  @override
  void initState() {
    super.initState();
    _player = YoutubePlayerController.fromVideoId(
      videoId: _videoId,
      params: const YoutubePlayerParams(
        // Our own buttons drive it, so the chords' clock isn't wound around by seeking.
        showControls: false,
        showFullscreenButton: false,
        enableCaption: false,
        strictRelatedVideos: true,
        playsInline: true,
        // Taps on the video would start it without finding chords; our buttons drive it.
        pointerEvents: PointerEvents.none,
      ),
    );
    _videoState = _player.videoStateStream.listen((s) {
      _position = s.position;
      _positionAt = DateTime.now();
    });
    _playerValue = _player.listen((v) async {
      if (v.playerState == _state) return;
      _state = v.playerState;
      if (_state == PlayerState.ended && _finding) await _stopFinding();
      if (_duration == 0 && _state != PlayerState.unknown) _duration = await _player.duration;
      if (mounted) setState(() {});
    });
    PlaybackListener.isSupported().then((ok) {
      if (mounted) setState(() => _captureSupported = ok);
    });
    _capture.addListener(_onCaptureChange);
  }

  @override
  void dispose() {
    _captured?.cancel();
    _videoState?.cancel();
    _playerValue?.cancel();
    _capture.removeListener(_onCaptureChange);
    _capture.dispose();
    _player.close();
    super.dispose();
  }

  PlaybackStatus? _shownStatus;

  /// The capture notifies on every chunk of sound (for its level meter, which listens for
  /// itself); the screen, video included, only rebuilds when the status changes.
  void _onCaptureChange() {
    if (_capture.status == _shownStatus) return;
    _shownStatus = _capture.status;
    // The system ended the capture (status bar, screen lock): stop finding too.
    if (_finding && _capture.status != PlaybackStatus.listening && _capture.status != PlaybackStatus.starting) {
      _finding = false;
      _player.pauseVideo();
    }
    if (mounted) setState(() {});
  }

  /// Where the video is now, in seconds, between position reports.
  double get _now {
    var t = _position.inMilliseconds / 1000;
    if (_state == PlayerState.playing) t += DateTime.now().difference(_positionAt).inMilliseconds / 1000;
    return t;
  }

  int _debugFrames = 0, _debugUsed = 0, _debugSound = 0;

  void _onFrame(AnalysisFrame f) {
    assert(() {
      _debugFrames++;
      if (f.hasSound) _debugSound++;
      if (_debugFrames % 20 == 0) {
        debugPrint('VideoFinder: frames=$_debugFrames used=$_debugUsed sound=$_debugSound '
            'finding=$_finding state=$_state rms=${f.rms.toStringAsFixed(4)} t=${_now.toStringAsFixed(1)} '
            'live=${_finder.live} conf=${_finder.liveConfidence.toStringAsFixed(2)} chords=${_finder.chords.length}');
      }
      return true;
    }());
    if (!_finding || _state != PlayerState.playing) return;
    assert(() {
      _debugUsed++;
      return true;
    }());
    if (_finder.add(f, at: _now) && mounted) setState(() {});
  }

  Future<void> _startFinding() async {
    if (_captureSupported == true) {
      await _capture.start();
      if (!mounted) return;
      if (_capture.status != PlaybackStatus.listening) {
        if (mounted) setState(() {});
        return;
      }
      _captured ??= _capture.frames.listen(_onFrame);
    }
    setState(() => _finding = true);
    await _player.playVideo();
  }

  Future<void> _stopFinding() async {
    _finding = false;
    await _player.pauseVideo();
    if (_captureSupported == true) await _capture.stop();
    if (mounted) setState(() {});
  }

  Future<void> _startOver() async {
    await _stopFinding();
    _finder.clear();
    await _player.seekTo(seconds: 0);
    await _player.pauseVideo();
    if (mounted) setState(() {});
  }

  void _makeSheet() {
    context.read<Analytics>()
        .chordsFound(source: 'video', chords: _finder.chords.length, melody: _finder.melody.tune.isNotEmpty);
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) => SheetEditorScreen(
        song: UserSong(id: '', title: '', link: widget.link, body: _finder.toSheetText()),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final resolver = context.read<AppServices>().resolver;
    final live = _finder.live;
    final liveChord = live == null ? null : resolver.resolve(live);
    final playing = _state == PlayerState.playing || _state == PlayerState.buffering;
    final useMic = _captureSupported == false;
    final primary = switch ((_finding, playing)) {
      (false, _) => (Icons.play_arrow_rounded, _finder.chords.isEmpty ? 'Play and find chords' : 'Keep going'),
      (true, true) => (Icons.pause_rounded, 'Pause'),
      (true, false) => (Icons.play_arrow_rounded, 'Resume'),
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Find chords from video')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: YoutubePlayer(controller: _player, enableFullScreenOnVerticalDrag: false, autoFullScreen: false),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Text(formatSeconds(_now), style: const TextStyle(color: kMuted, fontSize: 12)),
            const SizedBox(width: 8),
            Expanded(
              child: LinearProgressIndicator(
                value: _duration > 0 ? (_now / _duration).clamp(0.0, 1.0) : 0,
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Text(formatSeconds(_duration), style: const TextStyle(color: kMuted, fontSize: 12)),
          ]),
          const SizedBox(height: 14),
          if (_captureSupported == null)
            const SizedBox.shrink()
          else
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(14)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(useMic ? Icons.volume_up_rounded : Icons.graphic_eq_rounded, color: kAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    useMic
                        ? 'Guitaro listens through the mic, so turn the speaker up and keep the room quiet. '
                            'Chords land where they start in the video.'
                        : 'Guitaro listens to the video as it plays, nothing is downloaded. Android asks you '
                            'to allow it first; the capture runs only while finding chords.',
                    style: const TextStyle(height: 1.4),
                  ),
                ),
              ]),
            ),
          const SizedBox(height: 16),
          SizedBox(
            height: 150,
            child: Center(
              child: !_finding && _finder.chords.isEmpty
                  ? const Text('Press play; chords appear as the video plays.',
                      style: TextStyle(color: kMuted, fontSize: 16), textAlign: TextAlign.center)
                  : liveChord == null
                      ? Text(_finding && playing ? 'Listening…' : 'Paused',
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: kMuted))
                      : Column(mainAxisSize: MainAxisSize.min, children: [
                          ChordView(chord: liveChord, width: 90, compact: true),
                          Text('${(_finder.liveConfidence * 100).round()}% sure',
                              style: const TextStyle(color: kMuted, fontSize: 13)),
                        ]),
            ),
          ),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _captureSupported == null || _capture.status == PlaybackStatus.starting
                    ? null
                    : () => !_finding
                        ? _startFinding()
                        : playing
                            ? _player.pauseVideo()
                            : _player.playVideo(),
                icon: Icon(primary.$1),
                label: Text(primary.$2),
              ),
            ),
            if (_finding) ...[
              const SizedBox(width: 10),
              IconButton.filledTonal(tooltip: 'Done', onPressed: _stopFinding, icon: const Icon(Icons.stop_rounded)),
            ],
            if (_finder.chords.isNotEmpty && !_finding) ...[
              const SizedBox(width: 10),
              IconButton.outlined(
                  tooltip: 'Start over', onPressed: _startOver, icon: const Icon(Icons.restart_alt_rounded)),
            ],
          ]),
          if (_finding || _capture.status == PlaybackStatus.denied || _capture.status == PlaybackStatus.error) ...[
            const SizedBox(height: 12),
            if (useMic)
              _MicFeed(onFrame: _onFrame, message: live == null ? null : 'Hearing $live')
            else
              _CaptureBadge(capture: _capture, message: live == null ? null : 'Hearing $live', onRetry: _startFinding),
          ],
          const SizedBox(height: 20),
          Text(
            _finder.chords.isEmpty
                ? 'Chords will appear here'
                : '${_finder.chords.length} chord changes · ${_finder.melody.tune.length} melody notes',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in _finder.chords)
              ActionChip(
                tooltip: 'Play from here',
                onPressed: () => _player.seekTo(seconds: c.start, allowSeekAhead: true),
                label: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w800, color: kAccent)),
                avatar: Text(formatSeconds(c.start), style: const TextStyle(fontSize: 11, color: kMuted)),
              ),
          ]),
          if (_finder.chords.isNotEmpty) ...[
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: _finding ? null : _makeSheet,
              icon: const Icon(Icons.edit_note_rounded),
              label: const Text('Make it a song'),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Opens the editor with the video link saved: add the title and lyrics, fix any chords, '
                'then use Play along to practise.',
                style: TextStyle(color: kMuted, fontSize: 13),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Playback capture state, in the style of the mic badge.
class _CaptureBadge extends StatelessWidget {
  const _CaptureBadge({required this.capture, required this.message, required this.onRetry});

  final PlaybackListener capture;
  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (icon, text, color) = switch (capture.status) {
      PlaybackStatus.listening => (Icons.graphic_eq_rounded, message ?? 'Listening to the video…', kSuccess),
      PlaybackStatus.starting => (Icons.hourglass_top_rounded, 'Waiting for permission…', kMuted),
      PlaybackStatus.idle => (Icons.pause_circle_outline_rounded, 'Not listening', kMuted),
      PlaybackStatus.denied => (
          Icons.block_rounded,
          'Capture wasn\'t allowed. Tap retry and choose "Start now" (and allow the microphone if asked).',
          kMiss
        ),
      PlaybackStatus.error => (Icons.error_outline_rounded, 'Capture problem: ${capture.errorMessage ?? 'unknown'}', kMiss),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: kSurfaceHigh, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(color: color == kSuccess ? null : color, fontWeight: FontWeight.w600))),
        if (capture.status == PlaybackStatus.listening)
          ListenableBuilder(listenable: capture, builder: (context, _) => LevelMeter(level: capture.level)),
        if (capture.status == PlaybackStatus.denied || capture.status == PlaybackStatus.error)
          TextButton(onPressed: onRetry, child: const Text('Retry')),
      ]),
    );
  }
}

/// Mic fallback: holds the mic while on screen and forwards frames.
class _MicFeed extends StatefulWidget {
  const _MicFeed({required this.onFrame, required this.message});

  final void Function(AnalysisFrame) onFrame;
  final String? message;

  @override
  State<_MicFeed> createState() => _MicFeedState();
}

class _MicFeedState extends State<_MicFeed> with Listening {
  @override
  void onFrame(AnalysisFrame frame) => widget.onFrame(frame);

  @override
  Widget build(BuildContext context) => ListeningBadge(message: widget.message);
}
