import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../sheets/chord_sheet.dart';
import '../../sheets/songbook_store.dart';
import '../theme.dart';
import 'sheet_body.dart';

const _example = '''[Verse]
G              C          G
Write your own song or paste one here
         D               G
Chords go on the line above the words

{comment: ChordPro works too}
[G]Or put [C]chords in[D] brackets

e|-----0---------|
B|---1---1-------|
G|-2-------2-----|
D|---------------|
A|---------------|
E|---------------|''';

/// Write or paste a song: ChordPro or chords over lyrics, with tab. Shows a live preview.
class SheetEditorScreen extends StatefulWidget {
  const SheetEditorScreen({super.key, this.song});

  /// The song to edit, or null for a new one.
  final UserSong? song;

  @override
  State<SheetEditorScreen> createState() => _SheetEditorScreenState();
}

class _SheetEditorScreenState extends State<SheetEditorScreen> {
  late final _title = TextEditingController(text: widget.song?.title ?? '');
  late final _artist = TextEditingController(text: widget.song?.artist ?? '');
  late final _key = TextEditingController(text: widget.song?.key ?? '');
  late final _body = TextEditingController(text: widget.song?.body ?? '');
  late final _link = TextEditingController(text: widget.song?.link ?? '');
  late int _capo = widget.song?.capo ?? 0;
  bool _preview = false;

  @override
  void dispose() {
    for (final c in [_title, _artist, _key, _body, _link]) {
      c.dispose();
    }
    super.dispose();
  }

  UserSong get _draft => UserSong(
        id: widget.song?.id ?? '',
        title: _title.text,
        artist: _artist.text,
        key: _key.text,
        capo: _capo,
        tempo: widget.song?.tempo,
        link: youtubeUrl(_link.text),
        body: _body.text,
      );

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted || text == null || text.trim().isEmpty) return;
    setState(() {
      _body.text = text;
      // Pick up a title and artist from pasted ChordPro.
      final parsed = ChordSheet.parse(text, id: 'paste');
      if (_title.text.isEmpty && parsed.title != 'Untitled') _title.text = parsed.title;
      if (_artist.text.isEmpty) _artist.text = parsed.artist;
      if (_key.text.isEmpty && parsed.key != null) _key.text = parsed.key!;
      if (_capo == 0) _capo = parsed.capo;
    });
  }

  void _save() {
    final draft = _draft;
    if (draft.body.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add some chords or lyrics first.')));
      return;
    }
    if (_link.text.trim().isNotEmpty && draft.link == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("That doesn't look like a YouTube link.")));
      return;
    }
    final parsed = ChordSheet.parse(draft.body, id: 'draft');
    final title = draft.title.trim().isNotEmpty ? draft.title : (parsed.title != 'Untitled' ? parsed.title : 'My song');
    context.read<SongbookStore>().saveUserSong(
          UserSong(
            id: draft.id,
            title: title,
            artist: draft.artist,
            key: draft.key,
            capo: draft.capo,
            tempo: draft.tempo,
            link: draft.link,
            body: draft.body,
          ),
        );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text((widget.song?.id ?? '').isEmpty ? 'New song' : 'Edit song'),
        actions: [
          IconButton(
            tooltip: _preview ? 'Edit' : 'Preview',
            onPressed: () => setState(() => _preview = !_preview),
            icon: Icon(_preview ? Icons.edit_rounded : Icons.visibility_rounded),
          ),
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: SafeArea(
        child: _preview
            ? ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    _title.text.isEmpty ? 'Untitled' : _title.text,
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                  ),
                  if (_artist.text.isNotEmpty) Text(_artist.text, style: const TextStyle(color: kMuted)),
                  const SizedBox(height: 12),
                  SheetBody(sheet: _draft.toSheet()),
                ],
              )
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  TextField(
                    controller: _title,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _artist,
                    decoration: const InputDecoration(labelText: 'Artist or writer'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _link,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'YouTube link (optional)',
                      prefixIcon: Icon(Icons.smart_display_rounded),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _key,
                          decoration: const InputDecoration(labelText: 'Key (optional)'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      const Text('Capo'),
                      IconButton(
                        onPressed: _capo > 0 ? () => setState(() => _capo--) : null,
                        icon: const Icon(Icons.remove_rounded),
                      ),
                      Text('$_capo', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      IconButton(
                        onPressed: _capo < 9 ? () => setState(() => _capo++) : null,
                        icon: const Icon(Icons.add_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Song', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      ),
                      TextButton.icon(
                        onPressed: _paste,
                        icon: const Icon(Icons.content_paste_rounded),
                        label: const Text('Paste'),
                      ),
                    ],
                  ),
                  TextField(
                    controller: _body,
                    maxLines: null,
                    minLines: 14,
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(fontFamily: 'monospace', fontFamilyFallback: ['Courier'], fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: _example,
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Chords on the line above the lyric, or ChordPro with chords in [brackets]. '
                    'Section names like [Chorus] become headings, and six-line tab (e|--0--) gets a play button.',
                    style: TextStyle(color: kMuted, fontSize: 13),
                  ),
                ],
              ),
      ),
    );
  }
}
