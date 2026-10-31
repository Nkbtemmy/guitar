import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../sheets/songbook_store.dart';
import '../sheets/sheet_screen.dart';
import '../theme.dart';
import 'songs_screen.dart';

/// One setlist: drag to reorder, swipe to remove, play straight through.
class SetlistScreen extends StatelessWidget {
  const SetlistScreen({super.key, required this.setlistId});

  final String setlistId;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SongbookStore>();
    final setlist = store.setlist(setlistId);
    if (setlist == null) return Scaffold(appBar: AppBar());
    final ids = [
      for (final id in setlist.sheetIds)
        if (findSheet(context, id) != null) id,
    ];

    void open(String id) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SheetScreen(sheetId: id, queue: ids, queueName: setlist.name),
          ),
        );

    return Scaffold(
      appBar: AppBar(
        title: Text(setlist.name),
        actions: [
          IconButton(
            tooltip: 'Rename',
            onPressed: () async {
              final name = await promptForName(context, title: 'Rename setlist', initial: setlist.name);
              if (name != null && name.trim().isNotEmpty) store.renameSetlist(setlist.id, name.trim());
            },
            icon: const Icon(Icons.edit_rounded),
          ),
          IconButton(
            tooltip: 'Delete setlist',
            onPressed: () {
              Navigator.of(context).pop();
              store.deleteSetlist(setlist.id);
            },
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      floatingActionButton: ids.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => open(ids.first),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Play setlist'),
            ),
      body: SafeArea(
        child: ids.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No songs yet. Open a song and choose ⋮ › Add to setlist.',
                  style: TextStyle(color: kMuted),
                ),
              )
            : ReorderableListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
                onReorderItem: (from, to) {
                  final order = [...ids];
                  final id = order.removeAt(from);
                  order.insert(to.clamp(0, order.length), id);
                  store.arrangeSetlist(setlist.id, order);
                },
                children: [
                  for (final id in ids)
                    Dismissible(
                      key: ValueKey(id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.remove_circle_outline_rounded, color: kMiss),
                      ),
                      onDismissed: (_) => store.removeFromSetlist(setlist.id, id),
                      child: SheetTile(
                        sheet: findSheet(context, id)!,
                        onTap: () => open(id),
                        trailing: const Padding(
                          padding: EdgeInsets.only(right: 12),
                          child: Icon(Icons.drag_handle_rounded, color: kMuted),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
