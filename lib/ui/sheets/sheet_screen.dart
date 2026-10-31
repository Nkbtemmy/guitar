import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../analytics.dart';
import '../../app_services.dart';
import '../../sheets/chord_sheet.dart';
import '../../sheets/chord_symbol.dart';
import '../../sheets/sheet_song.dart';
import '../../sheets/songbook_store.dart';
import '../practice/song_view.dart';
import '../theme.dart';
import '../widgets/chord_view.dart';
import 'sheet_body.dart';
import 'sheet_editor.dart';

/// Finds a sheet by id among the bundled songs and the learner's own.
ChordSheet? findSheet(BuildContext context, String id) =>
    context.read<AppServices>().sheet(id) ?? context.read<SongbookStore>().userSong(id)?.toSheet();

/// A song sheet with the tools tab sites have: autoscroll, transpose, capo (with a
/// suggestion), simplified chords, text size, chord diagrams on tap, favorites and setlists.
/// With [queue], it steps through a setlist.
class SheetScreen extends StatefulWidget {
  const SheetScreen({super.key, required this.sheetId, this.queue = const [], this.queueName});

  final String sheetId;
  final List<String> queue;
  final String? queueName;

  @override
  State<SheetScreen> createState() => _SheetScreenState();
}

class _SheetScreenState extends State<SheetScreen> with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;
  bool _scrolling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<SongbookStore>().markViewed(widget.sheetId);
      context.read<Analytics>().songOpened(widget.sheetId);
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toggleScroll() {
    if (_scrolling) {
      _ticker.stop();
    } else {
      _last = Duration.zero;
      _ticker.start();
    }
    setState(() => _scrolling = !_scrolling);
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (!_scroll.hasClients) return;
    final speed = context.read<SongbookStore>().prefsFor(widget.sheetId).scrollSpeed;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent) {
      _ticker.stop();
      setState(() => _scrolling = false);
      return;
    }
    // Speed 1 is a slow ballad, 10 races; roughly 6..60 px a second.
    _scroll.jumpTo((pos.pixels + dt * 6 * speed).clamp(0.0, pos.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SongbookStore>();
    final sheet = findSheet(context, widget.sheetId);
    if (sheet == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This song was deleted.')),
      );
    }
    final resolver = context.read<AppServices>().resolver;
    final prefs = store.prefsFor(sheet.id);
    final capo = prefs.capo ?? sheet.capo;
    final display = SheetDisplay(
      shift: prefs.transpose - (capo - sheet.capo),
      capo: capo,
      simplify: prefs.simplify,
      fontScale: prefs.fontScale,
    );
    final sounding = [for (final n in sheet.chordNames) transposeName(n, prefs.transpose + sheet.capo)];
    final suggested = resolver.suggestCapo(sounding, simplify: prefs.simplify);
    final shapes = <String>{for (final n in sheet.chordNames) display.label(n, resolver)}.toList();
    final pos = widget.queue.indexOf(sheet.id);
    final next = pos >= 0 && pos + 1 < widget.queue.length ? findSheet(context, widget.queue[pos + 1]) : null;

    return Scaffold(
      appBar: AppBar(
        title: widget.queue.isEmpty
            ? null
            : Text(
                '${widget.queueName ?? 'Setlist'} · ${pos + 1} of ${widget.queue.length}',
                style: const TextStyle(fontSize: 15, color: kMuted),
              ),
        actions: [
          IconButton(
            tooltip: store.isFavorite(sheet.id) ? 'Remove from favorites' : 'Add to favorites',
            onPressed: () => store.toggleFavorite(sheet.id),
            icon: Icon(
              store.isFavorite(sheet.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              color: kAccent,
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => _menu(v, sheet),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'setlist', child: Text('Add to setlist')),
              const PopupMenuItem(value: 'copy', child: Text('Copy as ChordPro')),
              if (store.userSong(sheet.id) != null) ...[
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ] else
                const PopupMenuItem(value: 'duplicate', child: Text('Make my own copy')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
                children: [
                  Text(sheet.title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
                  if (sheet.artist.isNotEmpty) Text(sheet.artist, style: const TextStyle(color: kMuted, fontSize: 15)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (sheet.key != null) _Pill('Key ${transposeKey(sheet.key!, prefs.transpose)}'),
                      _Pill(capo > 0 ? 'Capo $capo' : 'No capo'),
                      if (prefs.transpose != 0) _Pill('Transposed ${prefs.transpose > 0 ? '+' : ''}${prefs.transpose}'),
                      if (sheet.difficulty != null) _Pill(sheet.difficulty!.label),
                      if (sheet.tempo != null) _Pill('${sheet.tempo} BPM'),
                      if (prefs.simplify) const _Pill('Simplified'),
                    ],
                  ),
                  if (suggested != capo && sounding.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: ActionChip(
                        avatar: const Icon(Icons.lightbulb_rounded, size: 18, color: kAccent),
                        label: Text(suggested == 0 ? 'Easier without a capo' : 'Easier with capo $suggested'),
                        onPressed: () => store.setPrefs(sheet.id, prefs.copyWith(capo: () => suggested)),
                      ),
                    ),
                  if (shapes.isNotEmpty || sheet.link != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Wrap(spacing: 8, runSpacing: 8, children: [
                        if (shapes.isNotEmpty)
                          FilledButton.icon(
                            onPressed: () => _playAlong(sheet, display, capo),
                            icon: const Icon(Icons.queue_music_rounded),
                            label: const Text('Play along'),
                            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                          ),
                        if (sheet.link != null)
                          OutlinedButton.icon(
                            onPressed: () => _openVideo(sheet.link!),
                            icon: const Icon(Icons.smart_display_rounded),
                            label: const Text('Watch on YouTube'),
                            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                          ),
                      ]),
                    ),
                  if (shapes.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 108,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: shapes.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 10),
                        itemBuilder: (context, i) {
                          final written = sheet.chordNames.firstWhere((n) => display.label(n, resolver) == shapes[i]);
                          final chord = display.voicing(written, resolver);
                          if (chord == null) return const SizedBox.shrink();
                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => showChordSheet(context, written, display),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: ChordView(chord: chord, width: 64, compact: true),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  SheetBody(sheet: sheet, display: display),
                  if (next != null) ...[
                    const SizedBox(height: 28),
                    FilledButton.icon(
                      onPressed: () => Navigator.of(context).pushReplacement(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              SheetScreen(sheetId: next.id, queue: widget.queue, queueName: widget.queueName),
                        ),
                      ),
                      icon: const Icon(Icons.skip_next_rounded),
                      label: Text('Next: ${next.title}'),
                    ),
                  ],
                ],
              ),
            ),
            _ControlBar(
              scrolling: _scrolling,
              speed: prefs.scrollSpeed,
              onToggle: _toggleScroll,
              onSpeed: (v) => store.setPrefs(sheet.id, prefs.copyWith(scrollSpeed: v)),
              onTools: () => _tools(sheet),
            ),
          ],
        ),
      ),
    );
  }

  /// Wait mode and play-along on this sheet, in the shapes currently shown (transpose, capo
  /// and simplify applied).
  void _playAlong(ChordSheet sheet, SheetDisplay display, int capo) {
    _ticker.stop();
    setState(() => _scrolling = false);
    final resolver = context.read<AppServices>().resolver;
    final song = sheetSong(sheet, shape: (n) => display.label(n, resolver), resolver: resolver);
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Play along')),
        body: SafeArea(
          child: SongView(song: song, chordFor: (name) => sheetChord(name, resolver), capo: capo),
        ),
      ),
    ));
  }

  Future<void> _openVideo(String link) async {
    final messenger = ScaffoldMessenger.of(context);
    bool ok;
    try {
      ok = await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok) messenger.showSnackBar(const SnackBar(content: Text("Couldn't open YouTube.")));
  }

  Future<void> _menu(String action, ChordSheet sheet) async {
    final store = context.read<SongbookStore>();
    final messenger = ScaffoldMessenger.of(context);
    switch (action) {
      case 'setlist':
        await showAddToSetlist(context, sheet.id);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: sheet.toChordPro()));
        messenger.showSnackBar(const SnackBar(content: Text('Copied as ChordPro')));
      case 'edit':
        await Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => SheetEditorScreen(song: store.userSong(sheet.id))));
      case 'duplicate':
        final copy = store.saveUserSong(
          UserSong(
            id: '',
            title: sheet.title,
            artist: sheet.artist,
            key: sheet.key ?? '',
            capo: sheet.capo,
            tempo: sheet.tempo,
            body: sheet.toChordPro(meta: false),
          ),
        );
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SheetEditorScreen(song: copy)));
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete "${sheet.title}"?'),
            content: const Text('It will also be removed from your favorites and setlists.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
            ],
          ),
        );
        if (ok == true && mounted) {
          Navigator.of(context).pop();
          store.deleteUserSong(sheet.id);
        }
    }
  }

  void _tools(ChordSheet sheet) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => _ToolsSheet(sheet: sheet),
      );
}

class _Pill extends StatelessWidget {
  const _Pill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: kSurfaceHigh, borderRadius: BorderRadius.circular(20)),
        child: Text(
          text,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: kTextSoft),
        ),
      );
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.scrolling,
    required this.speed,
    required this.onToggle,
    required this.onSpeed,
    required this.onTools,
  });

  final bool scrolling;
  final int speed;
  final VoidCallback onToggle, onTools;
  final ValueChanged<int> onSpeed;

  @override
  Widget build(BuildContext context) => Container(
        color: kSurface,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            IconButton.filled(
              tooltip: scrolling ? 'Stop autoscroll' : 'Autoscroll',
              onPressed: onToggle,
              icon: Icon(scrolling ? Icons.pause_rounded : Icons.keyboard_double_arrow_down_rounded),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Slower',
              onPressed: speed > 1 ? () => onSpeed(speed - 1) : null,
              icon: const Icon(Icons.remove_rounded),
            ),
            const Icon(Icons.speed_rounded, size: 18, color: kMuted),
            const SizedBox(width: 4),
            Text(
              '$speed',
              semanticsLabel: 'Speed $speed',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            IconButton(
              tooltip: 'Faster',
              onPressed: speed < 10 ? () => onSpeed(speed + 1) : null,
              icon: const Icon(Icons.add_rounded),
            ),
            const Spacer(),
            TextButton.icon(onPressed: onTools, icon: const Icon(Icons.tune_rounded), label: const Text('Tools')),
          ],
        ),
      );
}

/// Transpose, capo, simplify and text size, saved per song.
class _ToolsSheet extends StatelessWidget {
  const _ToolsSheet({required this.sheet});

  final ChordSheet sheet;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SongbookStore>();
    final prefs = store.prefsFor(sheet.id);
    final capo = prefs.capo ?? sheet.capo;
    // Each change starts from the stored settings, so quick repeated taps all count.
    void change(SheetPrefs Function(SheetPrefs p) f) => store.setPrefs(sheet.id, f(store.prefsFor(sheet.id)));
    int capoOf(SheetPrefs p) => p.capo ?? sheet.capo;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Stepper(
              label: 'Transpose',
              value: prefs.transpose == 0
                  ? 'Original'
                  : '${prefs.transpose > 0 ? '+' : ''}${prefs.transpose}'
                      '${sheet.key == null ? '' : ' · ${transposeKey(sheet.key!, prefs.transpose)}'}',
              onMinus: prefs.transpose > -11
                  ? () => change((p) => p.copyWith(transpose: (p.transpose - 1).clamp(-11, 11)))
                  : null,
              onPlus: prefs.transpose < 11
                  ? () => change((p) => p.copyWith(transpose: (p.transpose + 1).clamp(-11, 11)))
                  : null,
            ),
            _Stepper(
              label: 'Capo',
              value: capo == 0 ? 'None' : 'Fret $capo',
              onMinus: capo > 0 ? () => change((p) => p.copyWith(capo: () => (capoOf(p) - 1).clamp(0, 9))) : null,
              onPlus: capo < 9 ? () => change((p) => p.copyWith(capo: () => (capoOf(p) + 1).clamp(0, 9))) : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Simplify chords', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Plain triads and the easiest shapes (Am7 → Am, F → Fmaj7).'),
              value: prefs.simplify,
              onChanged: (v) => change((p) => p.copyWith(simplify: v)),
            ),
            Row(
              children: [
                const SizedBox(
                  width: 96,
                  child: Text('Text size', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
                Expanded(
                  child: Slider(
                    value: prefs.fontScale,
                    min: 0.8,
                    max: 1.6,
                    divisions: 8,
                    label: '${(prefs.fontScale * 100).round()}%',
                    onChanged: (v) => change((p) => p.copyWith(fontScale: v)),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => change((p) => SheetPrefs(scrollSpeed: p.scrollSpeed)),
                child: const Text('Reset to original'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.label, required this.value, this.onMinus, this.onPlus});

  final String label, value;
  final VoidCallback? onMinus, onPlus;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            IconButton.outlined(tooltip: '$label down', onPressed: onMinus, icon: const Icon(Icons.remove_rounded)),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton.outlined(tooltip: '$label up', onPressed: onPlus, icon: const Icon(Icons.add_rounded)),
          ],
        ),
      );
}

/// Lets the learner pick a setlist (or start a new one) for [sheetId].
Future<void> showAddToSetlist(BuildContext context, String sheetId) async {
  final store = context.read<SongbookStore>();
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Add to setlist', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          for (final s in store.setlists)
            ListTile(
              leading: const Icon(Icons.queue_music_rounded),
              title: Text(s.name),
              subtitle: Text('${s.sheetIds.length} songs'),
              trailing: s.sheetIds.contains(sheetId) ? const Icon(Icons.check_rounded, color: kSuccess) : null,
              onTap: () => Navigator.pop(context, s.id),
            ),
          ListTile(
            leading: const Icon(Icons.add_rounded),
            title: const Text('New setlist'),
            onTap: () => Navigator.pop(context, ''),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  var id = choice;
  if (id.isEmpty) {
    final name = await promptForName(context, title: 'New setlist', initial: 'My setlist');
    if (name == null) return;
    id = store.createSetlist(name).id;
  }
  store.addToSetlist(id, sheetId);
  messenger.showSnackBar(SnackBar(content: Text('Added to ${store.setlist(id)?.name ?? 'setlist'}')));
}

/// A one-field dialog; returns the text, or null when cancelled.
Future<String?> promptForName(BuildContext context, {required String title, String initial = ''}) => showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(title: title, initial: initial),
    );

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});

  final String title, initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          controller: _controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, _controller.text), child: const Text('Save')),
        ],
      );
}
