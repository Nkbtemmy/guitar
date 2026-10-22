import 'package:flutter/services.dart';

import 'audio/chord_matcher.dart';
import 'audio/sound_player.dart';
import 'curriculum/models.dart';
import 'music/chord_library.dart';
import 'video/video_catalog.dart';

/// Read-only content plus the shared sound player and chord matcher.
class AppServices {
  AppServices({required this.library, required this.curriculum, required this.player, VideoCatalog? videos})
      : matcher = ChordMatcher(library.chords),
        videos = videos ?? VideoCatalog(const []);

  final ChordLibrary library;
  final Curriculum curriculum;
  final SoundPlayer player;
  final ChordMatcher matcher;
  final VideoCatalog videos;

  static Future<AppServices> load(AssetBundle bundle, SoundPlayer player) async => AppServices(
        library: ChordLibrary.fromJson(
          await bundle.loadString('assets/data/chords.json'),
          tipsJson: await bundle.loadString('assets/data/chord_tips.json'),
        ),
        curriculum: Curriculum.fromJson(await bundle.loadString('assets/data/curriculum.json')),
        player: player,
        videos: await VideoCatalog.load(bundle),
      );
}
