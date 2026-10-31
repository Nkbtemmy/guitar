import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../progress/practice_log.dart';
import '../sheets/sheet_body.dart';
import '../sheets/sheet_screen.dart';
import '../theme.dart';
import 'song_view.dart';

/// Goes straight to a weak spot: its song's line in play-along, looping, or its tab's bar,
/// looping. A spot whose song has since been deleted is dropped.
void openSpot(BuildContext context, WeakSpot spot) {
  final place = spot.place;
  switch (place.kind) {
    case SpotKind.song:
      final song = context.read<AppServices>().curriculum.songs[place.id];
      if (song == null) return _gone(context, spot);
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(spot.title)),
          body: SafeArea(child: SongView(song: song, place: place, startBar: spot.from, repeat: true)),
        ),
      ));
    case SpotKind.sheet:
      if (findSheet(context, place.id) == null) return _gone(context, spot);
      openPlayAlong(context, place.id, startBar: spot.from, repeat: true);
    case SpotKind.tab:
      final sheet = findSheet(context, place.id);
      if (sheet == null) return _gone(context, spot);
      openTabPlayer(context, sheet, place.index, from: spot.from, to: spot.to);
  }
}

void _gone(BuildContext context, WeakSpot spot) {
  context.read<PracticeLog>().forget(spot);
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That song is no longer in your songbook.')));
}

/// The parts the learner keeps missing in play-along and tabs, most needed first: tap one to
/// loop it until it's right.
class WeakSpotsScreen extends StatelessWidget {
  const WeakSpotsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final spots = context.watch<PracticeLog>().weakSpots();
    return Scaffold(
      appBar: AppBar(title: const Text('Practise these')),
      body: SafeArea(
        child: spots.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'Nothing to fix yet. Play along with songs and tabs: the parts you miss show up here, '
                    'ready to practise.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kMuted, fontSize: 16, height: 1.4),
                  ),
                ),
              )
            : ListView(padding: const EdgeInsets.all(16), children: [
                const Text('Tap one to loop it until it comes out right.', style: TextStyle(color: kMuted)),
                const SizedBox(height: 10),
                for (final spot in spots) _SpotCard(spot: spot),
              ]),
      ),
    );
  }
}

class _SpotCard extends StatelessWidget {
  const _SpotCard({required this.spot});

  final WeakSpot spot;

  @override
  Widget build(BuildContext context) {
    final played = spot.misses + spot.hits;
    final days = DateTime.now().difference(spot.last).inDays;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        leading: Icon(spot.place.kind == SpotKind.tab ? Icons.queue_music_rounded : Icons.music_note_rounded, color: kAccent),
        title: Text(spot.title, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(
          '${spot.detail}\nMissed ${spot.misses} of $played · ${days == 0 ? 'today' : days == 1 ? 'yesterday' : '$days days ago'}',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: true,
        onTap: () => openSpot(context, spot),
        trailing: IconButton(
          tooltip: 'Got it: take it off the list',
          icon: const Icon(Icons.check_circle_outline_rounded),
          onPressed: () => context.read<PracticeLog>().forget(spot),
        ),
      ),
    );
  }
}
