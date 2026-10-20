import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../curriculum/models.dart';
import '../../progress/progress_store.dart';
import '../practice/song_view.dart';
import '../theme.dart';

/// Every song in the course. A song unlocks with the lesson that introduces it.
class SongsScreen extends StatelessWidget {
  const SongsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final progress = context.watch<ProgressStore>();
    final curriculum = services.curriculum;
    final songs = curriculum.songs.values.toList();
    return ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 24), children: [
      const Text('Songbook', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
      const SizedBox(height: 4),
      const Text('Public-domain classics, arranged for the chords you learn.', style: TextStyle(color: kMuted)),
      const SizedBox(height: 16),
      for (final song in songs) ...[
        _SongTile(
          song: song,
          chords: song.chordIds.map((c) => services.library.byId(c).symbol).join('  '),
          unlocked: _unlocked(curriculum, progress, song),
        ),
        const SizedBox(height: 10),
      ],
    ]);
  }

  bool _unlocked(Curriculum c, ProgressStore p, Song song) {
    final id = c.lessonForSong(song.id);
    if (id == null) return true;
    return p.isUnlocked(c, c.lessons.firstWhere((l) => l.id == id));
  }
}

class _SongTile extends StatelessWidget {
  const _SongTile({required this.song, required this.chords, required this.unlocked});

  final Song song;
  final String chords;
  final bool unlocked;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: unlocked ? 1 : 0.45,
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: CircleAvatar(
              backgroundColor: kAccent.withValues(alpha: 0.15),
              child: Icon(unlocked ? Icons.music_note_rounded : Icons.lock_rounded, color: kAccent),
            ),
            title: Text(song.title, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('$chords · ${song.bpm} BPM', style: const TextStyle(color: kMuted)),
            onTap: unlocked
                ? () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => Scaffold(appBar: AppBar(), body: SafeArea(child: SongView(song: song))),
                    ))
                : () => ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Keep going through the lessons to unlock this song.'))),
          ),
        ),
      );
}
