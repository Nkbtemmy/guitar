import 'package:flutter/services.dart';

import 'audio/chord_matcher.dart';
import 'audio/sound_player.dart';
import 'curriculum/models.dart';
import 'music/chord_library.dart';
import 'sheets/chord_resolver.dart';
import 'sheets/chord_sheet.dart';
import 'video/video_catalog.dart';

/// Read-only content plus the shared sound player and chord matcher.
class AppServices {
  AppServices({
    required this.library,
    required this.curriculum,
    required this.player,
    VideoCatalog? videos,
    List<ChordSheet> sheets = const [],
  })  : matcher = ChordMatcher(library.chords),
        resolver = ChordResolver(library),
        videos = videos ?? VideoCatalog(const []),
        sheets = List.unmodifiable([...sheets]..sort((a, b) => a.title.compareTo(b.title)));

  final ChordLibrary library;
  final Curriculum curriculum;
  final SoundPlayer player;
  final ChordMatcher matcher;
  final ChordResolver resolver;
  final VideoCatalog videos;

  /// The bundled public-domain song sheets (assets/songs/*.cho).
  final List<ChordSheet> sheets;

  late final Map<String, ChordSheet> _sheetsById = {for (final s in sheets) s.id: s};

  ChordSheet? sheet(String id) => _sheetsById[id];

  static Future<AppServices> load(AssetBundle bundle, SoundPlayer player) async => AppServices(
        library: ChordLibrary.fromJson(
          await bundle.loadString('assets/data/chords.json'),
          tipsJson: await bundle.loadString('assets/data/chord_tips.json'),
        ),
        curriculum: Curriculum.fromJson(await bundle.loadString('assets/data/curriculum.json')),
        player: player,
        videos: await VideoCatalog.load(bundle),
        sheets: await loadSheets(bundle),
      );

  static Future<List<ChordSheet>> loadSheets(AssetBundle bundle) async {
    final manifest = await AssetManifest.loadFromAssetBundle(bundle);
    final paths = manifest.listAssets().where((p) => p.startsWith('assets/songs/') && p.endsWith('.cho'));
    return [for (final p in paths) ChordSheet.parse(await bundle.loadString(p), id: sheetIdForAsset(p))];
  }

  /// "assets/songs/amazing_grace.cho" → "pd:amazing_grace".
  static String sheetIdForAsset(String path) => 'pd:${path.split('/').last.replaceAll('.cho', '')}';
}
