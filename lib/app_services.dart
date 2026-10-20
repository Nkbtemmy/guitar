import 'package:flutter/services.dart';

import 'audio/chord_matcher.dart';
import 'audio/sound_player.dart';
import 'curriculum/models.dart';
import 'music/chord_library.dart';

/// Read-only content plus the shared sound player and chord matcher.
class AppServices {
  AppServices({required this.library, required this.curriculum, required this.player})
      : matcher = ChordMatcher(library.chords);

  final ChordLibrary library;
  final Curriculum curriculum;
  final SoundPlayer player;
  final ChordMatcher matcher;

  static Future<AppServices> load(AssetBundle bundle, SoundPlayer player) async => AppServices(
        library: ChordLibrary.fromJson(
          await bundle.loadString('assets/data/chords.json'),
          tipsJson: await bundle.loadString('assets/data/chord_tips.json'),
        ),
        curriculum: Curriculum.fromJson(await bundle.loadString('assets/data/curriculum.json')),
        player: player,
      );
}
