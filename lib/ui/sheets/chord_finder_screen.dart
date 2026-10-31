import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../analytics.dart';
import '../../app_services.dart';
import '../../audio/analysis.dart';
import '../../sheets/chord_finder.dart';
import '../../sheets/chord_sheet.dart';
import '../../sheets/songbook_store.dart';
import '../theme.dart';
import '../widgets/chord_view.dart';
import '../widgets/listening.dart';
import '../widgets/listening_badge.dart';
import 'sheet_editor.dart';
import 'video_finder_screen.dart';

/// Finds a song's chords by listening: play it out loud (YouTube on a TV, laptop or speaker)
/// and the chords are written down as they're heard. The result opens in the editor as a new
/// song, ready to fix up, save and practise with play-along.
class ChordFinderScreen extends StatefulWidget {
  const ChordFinderScreen({super.key});

  @override
  State<ChordFinderScreen> createState() => _ChordFinderScreenState();
}

class _ChordFinderScreenState extends State<ChordFinderScreen> {
  final _finder = ChordFinder();
  final _link = TextEditingController();
  bool _listening = false;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  String? get _video => youtubeUrl(_link.text);

  Future<void> _openVideo() async {
    final messenger = ScaffoldMessenger.of(context);
    final url = _video;
    if (url == null) {
      messenger.showSnackBar(const SnackBar(content: Text("That doesn't look like a YouTube link.")));
      return;
    }
    bool ok;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok) messenger.showSnackBar(const SnackBar(content: Text("Couldn't open YouTube.")));
  }

  void _makeSheet() {
    context.read<Analytics>()
        .chordsFound(source: 'mic', chords: _finder.chords.length, melody: _finder.melody.tune.isNotEmpty);
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) => SheetEditorScreen(
        song: UserSong(id: '', title: '', link: _video, body: _finder.toSheetText()),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final resolver = context.read<AppServices>().resolver;
    final live = _finder.live;
    final liveChord = live == null ? null : resolver.resolve(live);
    return Scaffold(
      appBar: AppBar(title: const Text('Find chords')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(14)),
            child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.hearing_rounded, color: kAccent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Play the song out loud on another device (a TV, laptop or speaker) near your phone. '
                  'Guitaro listens and writes down the chords, and the melody as tab. Clear guitar or piano '
                  'songs work best; with drums and vocals, expect to fix a few chords and notes.',
                  style: TextStyle(height: 1.4),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _link,
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'YouTube link (optional)',
              helperText: 'Saved with the song so you can watch it while you learn.',
              prefixIcon: const Icon(Icons.smart_display_rounded),
              suffixIcon: _link.text.trim().isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Open in YouTube', onPressed: _openVideo, icon: const Icon(Icons.open_in_new_rounded)),
            ),
          ),
          if (_video != null && !_listening) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(builder: (_) => VideoFinderScreen(link: _video!))),
              icon: const Icon(Icons.smart_display_rounded),
              label: const Text('Play it here and find chords'),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'The video plays in Guitaro and the chords are written down in time with it. '
                'Or carry on below to listen through the mic.',
                style: TextStyle(color: kMuted, fontSize: 13),
              ),
            ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            height: 190,
            child: Center(
              child: !_listening && _finder.chords.isEmpty
                  ? const Text('Press start, then play the song.', style: TextStyle(color: kMuted, fontSize: 16))
                  : liveChord == null
                      ? Text(_listening ? 'Listening…' : 'Paused',
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: kMuted))
                      : Column(mainAxisSize: MainAxisSize.min, children: [
                          ChordView(chord: liveChord, width: 100, compact: true),
                          Text('${(_finder.liveConfidence * 100).round()}% sure',
                              style: const TextStyle(color: kMuted, fontSize: 13)),
                        ]),
            ),
          ),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => setState(() => _listening = !_listening),
                icon: Icon(_listening ? Icons.pause_rounded : Icons.mic_rounded),
                label: Text(_listening ? 'Pause' : (_finder.chords.isEmpty ? 'Start listening' : 'Keep listening')),
              ),
            ),
            if (_finder.chords.isNotEmpty && !_listening) ...[
              const SizedBox(width: 10),
              IconButton.outlined(
                tooltip: 'Start over',
                onPressed: () => setState(_finder.clear),
                icon: const Icon(Icons.restart_alt_rounded),
              ),
            ],
          ]),
          if (_listening) ...[
            const SizedBox(height: 12),
            _FinderListener(finder: _finder, onChange: () => setState(() {})),
          ],
          const SizedBox(height: 20),
          Text(
            _finder.chords.isEmpty
                ? 'Chords will appear here'
                : '${_finder.chords.length} chord changes · ${_finder.melody.tune.length} melody notes · '
                    '${formatSeconds(_finder.elapsed)}',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in _finder.chords)
              Chip(
                label: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w800, color: kAccent)),
                avatar: Text(formatSeconds(c.start), style: const TextStyle(fontSize: 11, color: kMuted)),
              ),
          ]),
          if (_finder.chords.isNotEmpty) ...[
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: _listening ? null : _makeSheet,
              icon: const Icon(Icons.edit_note_rounded),
              label: const Text('Make it a song'),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Opens the editor: add the title and lyrics, fix any chords, save, then use Play along to practise.',
                style: TextStyle(color: kMuted, fontSize: 13),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Holds the mic only while listening and feeds frames to the finder.
class _FinderListener extends StatefulWidget {
  const _FinderListener({required this.finder, required this.onChange});

  final ChordFinder finder;
  final VoidCallback onChange;

  @override
  State<_FinderListener> createState() => _FinderListenerState();
}

class _FinderListenerState extends State<_FinderListener> with Listening {
  @override
  void onFrame(AnalysisFrame frame) {
    if (widget.finder.add(frame)) widget.onChange();
  }

  @override
  Widget build(BuildContext context) =>
      ListeningBadge(message: widget.finder.live == null ? null : 'Hearing ${widget.finder.live}');
}
