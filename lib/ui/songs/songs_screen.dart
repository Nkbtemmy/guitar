import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../curriculum/models.dart';
import '../../progress/progress_store.dart';
import '../../sheets/chord_sheet.dart';
import '../../sheets/songbook_store.dart';
import '../practice/song_view.dart';
import '../sheets/chord_finder_screen.dart';
import '../sheets/sheet_editor.dart';
import '../sheets/sheet_screen.dart';
import '../theme.dart';
import 'setlist_screen.dart';

/// The songbook: course songs to practise with the mic, public-domain chord sheets and tabs,
/// saved songs and setlists, and the learner's own songs.
class SongsScreen extends StatelessWidget {
  const SongsScreen({super.key});

  @override
  Widget build(BuildContext context) => const DefaultTabController(
        length: 3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Text('Songbook', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
            ),
            TabBar(
              tabAlignment: TabAlignment.start,
              isScrollable: true,
              labelStyle: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              tabs: [
                Tab(text: 'Explore'),
                Tab(text: 'Saved'),
                Tab(text: 'My songs'),
              ],
            ),
            Expanded(child: TabBarView(children: [_ExploreTab(), _SavedTab(), _MySongsTab()])),
          ],
        ),
      );
}

enum _Filter {
  all('All'),
  beginner('Beginner'),
  intermediate('Intermediate'),
  advanced('Advanced'),
  tab('With tab');

  const _Filter(this.label);

  final String label;

  bool accepts(ChordSheet s) => switch (this) {
        all => true,
        tab => s.hasTab,
        _ => s.difficulty?.name == name,
      };
}

class _ExploreTab extends StatefulWidget {
  const _ExploreTab();

  @override
  State<_ExploreTab> createState() => _ExploreTabState();
}

class _ExploreTabState extends State<_ExploreTab> {
  String _query = '';
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final progress = context.watch<ProgressStore>();
    final curriculum = services.curriculum;
    final q = _query.trim().toLowerCase();
    final courseSongs = [
      if (_filter == _Filter.all)
        for (final song in curriculum.songs.values)
          if (q.isEmpty || '${song.title} ${song.credit}'.toLowerCase().contains(q)) song,
    ];
    final sheets = [
      for (final s in services.sheets)
        if (_filter.accepts(s) && (q.isEmpty || s.searchText.contains(q))) s,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        TextField(
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            hintText: 'Search songs, artists, styles',
            filled: true,
            fillColor: kSurface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final f in _Filter.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(f.label),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                  ),
                ),
            ],
          ),
        ),
        if (sheets.isNotEmpty) ...[
          const _Heading('Chords & tabs', 'Public-domain songs. Transpose, capo, autoscroll, and tabs you can play.'),
          for (final s in sheets) SheetTile(sheet: s),
        ],
        if (courseSongs.isNotEmpty) ...[
          const _Heading('Practise with the app', 'Wait mode and play-along listen to you play.'),
          for (final song in courseSongs) ...[
            _SongTile(
              song: song,
              chords: song.chordIds.map((c) => services.library.byId(c).symbol).join('  '),
              unlocked: _unlocked(curriculum, progress, song),
            ),
            const SizedBox(height: 10),
          ],
        ],
        if (courseSongs.isEmpty && sheets.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(
              child: Text('No songs match.', style: TextStyle(color: kMuted)),
            ),
          ),
      ],
    );
  }

  bool _unlocked(Curriculum c, ProgressStore p, Song song) {
    final id = c.lessonForSong(song.id);
    if (id == null) return true;
    return p.isUnlocked(c, c.lessons.firstWhere((l) => l.id == id));
  }
}

class _SavedTab extends StatelessWidget {
  const _SavedTab();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SongbookStore>();
    final favorites = [for (final id in store.favorites) findSheet(context, id)].nonNulls.toList();
    final recent = [for (final id in store.recent) findSheet(context, id)].nonNulls.take(8).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        Row(
          children: [
            const Expanded(child: _Heading('Setlists', null)),
            TextButton.icon(
              onPressed: () async {
                final name = await promptForName(context, title: 'New setlist', initial: 'My setlist');
                if (name != null) store.createSetlist(name);
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('New'),
            ),
          ],
        ),
        if (store.setlists.isEmpty)
          const _Empty('Group songs for a practice session or a gig. Add songs from a song\'s ⋮ menu.'),
        for (final s in store.setlists)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: const Icon(Icons.queue_music_rounded, color: kAccent),
              title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                '${s.sheetIds.length} song${s.sheetIds.length == 1 ? '' : 's'}',
                style: const TextStyle(color: kMuted),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SetlistScreen(setlistId: s.id))),
            ),
          ),
        const _Heading('Favorites', null),
        if (favorites.isEmpty) const _Empty('Tap ♡ on any song to keep it here.'),
        for (final s in favorites) SheetTile(sheet: s),
        if (recent.isNotEmpty) ...[
          const _Heading('Recently viewed', null),
          for (final s in recent) SheetTile(sheet: s),
        ],
      ],
    );
  }
}

class _MySongsTab extends StatelessWidget {
  const _MySongsTab();

  @override
  Widget build(BuildContext context) {
    final songs = context.watch<SongbookStore>().userSongs;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        FilledButton.icon(
          onPressed: () =>
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SheetEditorScreen())),
          icon: const Icon(Icons.add_rounded),
          label: const Text('New song'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () =>
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ChordFinderScreen())),
          icon: const Icon(Icons.hearing_rounded),
          label: const Text('Find chords by listening'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
        ),
        const SizedBox(height: 8),
        if (songs.isEmpty)
          const _Empty(
            'Write your own songs, or paste chords and tabs you\'re allowed to use. '
            'They stay on this phone.',
          ),
        for (final song in songs) SheetTile(sheet: song.toSheet()),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.title, this.subtitle);

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            if (subtitle != null) Text(subtitle!, style: const TextStyle(color: kMuted)),
          ],
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(color: kMuted)),
      );
}

/// A song sheet in a list: title, artist, key and difficulty, with a favorite toggle.
class SheetTile extends StatelessWidget {
  const SheetTile({super.key, required this.sheet, this.onTap, this.trailing});

  final ChordSheet sheet;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SongbookStore>();
    final fav = store.isFavorite(sheet.id);
    final details = [
      if (sheet.artist.isNotEmpty) sheet.artist,
      if (sheet.key != null) 'Key ${sheet.key}',
      if (sheet.difficulty != null) sheet.difficulty!.label,
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 16, right: 4),
        leading: CircleAvatar(
          backgroundColor: kAccent.withValues(alpha: 0.15),
          child: Icon(sheet.hasLyrics ? Icons.lyrics_rounded : Icons.table_rows_rounded, color: kAccent),
        ),
        title: Text(sheet.title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          [details, if (sheet.hasTab && sheet.hasLyrics) 'Tab'].where((s) => s.isNotEmpty).join(' · '),
          style: const TextStyle(color: kMuted),
        ),
        trailing: trailing ??
            IconButton(
              tooltip: fav ? 'Remove from favorites' : 'Add to favorites',
              onPressed: () => store.toggleFavorite(sheet.id),
              icon: Icon(fav ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: kAccent),
            ),
        onTap: onTap ??
            () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SheetScreen(sheetId: sheet.id))),
      ),
    );
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
