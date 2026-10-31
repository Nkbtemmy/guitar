import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../practice/report.dart';
import '../../progress/practice_log.dart';
import '../../sheets/chord_sheet.dart';
import '../../sheets/songbook_store.dart';
import '../theme.dart';
import 'weak_spots_screen.dart';

/// Homework a teacher sets: a song or tab to play through at a speed, by a day. It ticks itself
/// off when the learner manages it (a whole run that fast, four in five right), or by hand.
class HomeworkScreen extends StatelessWidget {
  const HomeworkScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final log = context.watch<PracticeLog>();
    final homework = log.homework;
    final today = DateUtils.dateOnly(DateTime.now());
    return Scaffold(
      appBar: AppBar(title: const Text('Homework')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AddHomeworkScreen())),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Set homework'),
      ),
      body: SafeArea(
        child: homework.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'No homework yet. Teachers: set a song to practise, the speed to reach, and when it\'s due. '
                    'It ticks itself off when it\'s played through that well.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kMuted, fontSize: 16, height: 1.4),
                  ),
                ),
              )
            : ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
                for (final h in homework)
                  Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      leading: Checkbox(value: h.done, onChanged: (v) => log.setHomeworkDone(h, v ?? false)),
                      title: Text(h.title,
                          style: TextStyle(fontWeight: FontWeight.w800, decoration: h.done ? TextDecoration.lineThrough : null)),
                      subtitle: Text([
                        'At ${(h.tempo * 100).round()}% speed',
                        if (h.due != null)
                          !h.done && h.due!.isBefore(today) ? 'was due ${shortDate(h.due!)}' : 'by ${shortDate(h.due!)}',
                        if (h.note.isNotEmpty) h.note,
                      ].join(' · ')),
                      onTap: () => openPlace(context, h.place, title: h.title),
                      trailing: IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () => log.removeHomework(h),
                      ),
                    ),
                  ),
              ]),
      ),
    );
  }
}

/// A song or tab that homework can be set on.
typedef _Piece = ({String label, SpotPlace place});

/// Setting homework: what to play, how fast, by when, and a note.
class AddHomeworkScreen extends StatefulWidget {
  const AddHomeworkScreen({super.key});

  @override
  State<AddHomeworkScreen> createState() => _AddHomeworkScreenState();
}

class _AddHomeworkScreenState extends State<AddHomeworkScreen> {
  _Piece? _piece;
  double _tempo = 0.8;
  DateTime? _due;
  final _note = TextEditingController();

  /// Everything there is to set: songbook songs (and their tabs), then the course's songs.
  late final List<_Piece> _pieces = () {
    final services = context.read<AppServices>();
    final sheets = <ChordSheet>[
      ...services.sheets,
      for (final s in context.read<SongbookStore>().userSongs) s.toSheet(),
    ];
    return <_Piece>[
      for (final sheet in sheets) ...[
        if (sheet.chordNames.isNotEmpty) (label: sheet.title, place: SpotPlace.sheet(sheet.id)),
        for (final (i, block) in sheet.lines.whereType<TabLines>().indexed)
          if (block.sequence != null) (label: '${sheet.title} · ${block.label ?? 'tab'}', place: SpotPlace.tab(sheet.id, i)),
      ],
      for (final song in services.curriculum.songs.values) (label: '${song.title} (lesson)', place: SpotPlace.song(song.id)),
    ];
  }();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      firstDate: DateUtils.dateOnly(now),
      lastDate: now.add(const Duration(days: 180)),
      initialDate: _due ?? now.add(const Duration(days: 7)),
      helpText: 'Due by',
    );
    if (day != null) setState(() => _due = day);
  }

  void _save() {
    final piece = _piece;
    if (piece == null) return;
    context.read<PracticeLog>().addHomework(Homework(
          id: 'hw_${DateTime.now().microsecondsSinceEpoch}',
          place: piece.place,
          title: piece.label,
          tempo: _tempo,
          due: _due,
          note: _note.text.trim(),
        ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Set homework')),
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            const Text('What to play', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            DropdownMenu<_Piece>(
              expandedInsets: EdgeInsets.zero,
              enableFilter: true,
              requestFocusOnTap: true,
              hintText: 'Search the songbook',
              menuHeight: 320,
              dropdownMenuEntries: [for (final p in _pieces) DropdownMenuEntry(value: p, label: p.label)],
              onSelected: (p) => setState(() => _piece = p),
            ),
            const SizedBox(height: 20),
            Text('Speed to reach: ${(_tempo * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.w800)),
            Slider(
              value: _tempo,
              min: 0.5,
              max: 1.0,
              divisions: 10,
              label: '${(_tempo * 100).round()}%',
              onChanged: (v) => setState(() => _tempo = v),
            ),
            const Text('It counts as done when played start to finish this fast, with four bars (or notes) in five right.',
                style: TextStyle(color: kMuted, fontSize: 13)),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _pickDue,
              icon: const Icon(Icons.event_rounded),
              label: Text(_due == null ? 'Due date (optional)' : 'Due by ${shortDate(_due!)}'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'e.g. watch the change to D', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _piece == null ? null : _save, child: const Text('Set it')),
          ]),
        ),
      );
}
