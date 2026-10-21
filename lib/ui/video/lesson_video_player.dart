import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../app_services.dart';
import '../../video/video_catalog.dart';
import '../theme.dart';

/// 16:9 lesson video with tap-to-pause, scrubbing, time and a landscape fullscreen mode.
class LessonVideoPlayer extends StatefulWidget {
  const LessonVideoPlayer({super.key, required this.video, this.autoplay = true});

  final VideoInfo video;
  final bool autoplay;

  @override
  State<LessonVideoPlayer> createState() => _LessonVideoPlayerState();
}

class _LessonVideoPlayerState extends State<LessonVideoPlayer> {
  late final VideoCatalog _catalog = context.read<AppServices>().videos;
  late final VideoPlayerController _controller = _catalog.controllerFor(widget.video);
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTick);
    _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      if (widget.autoplay) _controller.play();
    }, onError: (Object e) {
      debugPrint('Video ${widget.video.id} failed to load: $e');
      if (mounted) setState(() => _failed = true);
    });
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    final v = _controller.value;
    if (!v.isInitialized) return;
    if (v.isPlaying) {
      _controller.pause();
    } else {
      if (v.position >= v.duration) _controller.seekTo(Duration.zero);
      _controller.play();
    }
  }

  Future<void> _fullscreen() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _FullscreenVideo(controller: _controller, title: widget.video.title),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final v = _controller.value;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: ColoredBox(
        color: Colors.black,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(fit: StackFit.expand, children: [
              if (v.isInitialized)
                VideoPlayer(_controller)
              else
                Image.asset(_catalog.posterAsset(widget.video), fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const ColoredBox(color: kSurface)),
              if (_failed)
                const Center(
                  child: Text('Video unavailable offline', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                )
              else
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _toggle,
                    child: AnimatedOpacity(
                      opacity: v.isPlaying ? 0 : 1,
                      duration: const Duration(milliseconds: 200),
                      child: Center(
                        child: v.isInitialized
                            ? const CircleAvatar(
                                radius: 32,
                                backgroundColor: kAccent,
                                child: Icon(Icons.play_arrow_rounded, color: kOnAccent, size: 42),
                              )
                            : const CircularProgressIndicator(color: Colors.white),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          if (v.isInitialized)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              child: Row(children: [
                Text('${_fmt(v.position)} / ${_fmt(v.duration)}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                const SizedBox(width: 10),
                Expanded(
                  child: VideoProgressIndicator(
                    _controller,
                    allowScrubbing: true,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    colors: _onBlack,
                  ),
                ),
                IconButton(
                  tooltip: 'Full screen',
                  icon: const Icon(Icons.fullscreen_rounded, color: Colors.white70),
                  onPressed: _fullscreen,
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}

// The controls sit on the black video frame, so they use white tones rather than the brand colors.
const _onBlack = VideoProgressColors(playedColor: Colors.white, bufferedColor: Colors.white38, backgroundColor: Colors.white12);

String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

class _FullscreenVideo extends StatefulWidget {
  const _FullscreenVideo({required this.controller, required this.title});

  final VideoPlayerController controller;
  final String title;

  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<_FullscreenVideo> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => c.value.isPlaying ? c.pause() : c.play(),
        child: Stack(children: [
          Center(child: AspectRatio(aspectRatio: 16 / 9, child: VideoPlayer(c))),
          Positioned(
            left: 8,
            top: 8,
            child: IconButton(
              tooltip: 'Exit full screen',
              icon: const Icon(Icons.fullscreen_exit_rounded, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 8,
            child: VideoProgressIndicator(
              c,
              allowScrubbing: true,
              colors: _onBlack,
            ),
          ),
        ]),
      ),
    );
  }
}

/// A standalone page for level intro videos.
class VideoScreen extends StatelessWidget {
  const VideoScreen({super.key, required this.video});

  final VideoInfo video;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(video.title)),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          LessonVideoPlayer(video: video),
          const SizedBox(height: 16),
          Text(video.subtitle, style: const TextStyle(fontSize: 16, color: kMuted)),
        ]),
      );
}
