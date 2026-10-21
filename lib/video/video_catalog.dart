import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

class VideoInfo {
  const VideoInfo({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.levelId,
    required this.duration,
    required this.file,
    required this.poster,
    this.lessonId,
  });

  final String id, kind, title, subtitle, levelId, file, poster;
  final String? lessonId;
  final Duration duration;

  bool get isIntro => kind == 'intro';

  factory VideoInfo.fromJson(Map<String, dynamic> j) => VideoInfo(
        id: j['id'] as String,
        kind: j['kind'] as String,
        title: j['title'] as String,
        subtitle: j['subtitle'] as String,
        levelId: j['levelId'] as String,
        lessonId: j['lessonId'] as String?,
        duration: Duration(milliseconds: ((j['duration'] as num) * 1000).round()),
        file: j['file'] as String,
        poster: j['poster'] as String,
      );
}

/// The rendered lesson and level-intro videos (assets/videos/index.json, written by
/// tools/video_render.py). Videos play from the app bundle, or from [baseUrl] when the app is
/// built with --dart-define=VIDEO_BASE_URL=https://your.host/videos.
class VideoCatalog {
  VideoCatalog(List<VideoInfo> videos)
      : _byLesson = {for (final v in videos) if (v.lessonId != null) v.lessonId!: v},
        _intros = {for (final v in videos) if (v.isIntro) v.levelId: v},
        all = List.unmodifiable(videos);

  static const baseUrl = String.fromEnvironment('VIDEO_BASE_URL');
  static const assetDir = 'assets/videos';

  final List<VideoInfo> all;
  final Map<String, VideoInfo> _byLesson, _intros;

  factory VideoCatalog.fromJson(String source) =>
      VideoCatalog([for (final v in jsonDecode(source) as List) VideoInfo.fromJson(v as Map<String, dynamic>)]);

  /// Missing index (videos not rendered yet) means an empty catalog, not an error.
  static Future<VideoCatalog> load(AssetBundle bundle) async {
    try {
      return VideoCatalog.fromJson(await bundle.loadString('$assetDir/index.json'));
    } catch (_) {
      return VideoCatalog(const []);
    }
  }

  VideoInfo? forLesson(String lessonId) => _byLesson[lessonId];
  VideoInfo? introFor(String levelId) => _intros[levelId];

  String posterAsset(VideoInfo v) => '$assetDir/${v.poster}';

  VideoPlayerController controllerFor(VideoInfo v) => baseUrl.isEmpty
      ? VideoPlayerController.asset('$assetDir/${v.file}')
      : VideoPlayerController.networkUrl(Uri.parse('$baseUrl/${v.file}'));
}
