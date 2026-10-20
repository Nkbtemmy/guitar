import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../audio/analysis.dart';
import '../../audio/chord_matcher.dart';
import '../../music/chord.dart';
import '../../music/chord_library.dart';
import '../lesson/steps.dart';
import '../theme.dart';
import '../widgets/chord_diagram.dart';
import '../widgets/listening.dart';
import '../widgets/listening_badge.dart';

class ChordsScreen extends StatelessWidget {
  const ChordsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final library = context.read<AppServices>().library;
    return CustomScrollView(slivers: [
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Text('Chords', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
        ),
      ),
      for (final MapEntry(key: category, value: title) in ChordLibrary.categories.entries) ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
            child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 120,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.72,
            ),
            itemCount: library.inCategory(category).length,
            itemBuilder: (context, i) => _ChordCard(chord: library.inCategory(category)[i]),
          ),
        ),
      ],
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ]);
  }
}

class _ChordCard extends StatelessWidget {
  const _ChordCard({required this.chord});

  final Chord chord;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChordDetailScreen(chord: chord))),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: LayoutBuilder(
              builder: (context, c) => ChordDiagram(chord: chord, width: c.maxWidth * 0.8, showName: true),
            ),
          ),
        ),
      );
}

class ChordDetailScreen extends StatefulWidget {
  const ChordDetailScreen({super.key, required this.chord});

  final Chord chord;

  @override
  State<ChordDetailScreen> createState() => _ChordDetailScreenState();
}

class _ChordDetailScreenState extends State<ChordDetailScreen> {
  bool _checking = false;

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final chord = widget.chord;
    return Scaffold(
      appBar: AppBar(title: Text(chord.name)),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Center(child: ChordDiagram(chord: chord, width: 200)),
        const SizedBox(height: 16),
        for (final line in chord.placement)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(line, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15)),
          ),
        if (chord.tip != null)
          Container(
            margin: const EdgeInsets.only(top: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: kSurfaceHigh, borderRadius: BorderRadius.circular(14)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.lightbulb_rounded, color: kAccent),
              const SizedBox(width: 10),
              Expanded(child: Text(chord.tip!, style: const TextStyle(height: 1.4))),
            ]),
          ),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          HearButton(onPressed: () => services.player.playChord(chord)),
          const SizedBox(width: 12),
          HearButton(label: 'String by string', onPressed: () => services.player.playChord(chord, slow: true)),
        ]),
        const SizedBox(height: 16),
        if (_checking)
          _ChordChecker(chord: chord)
        else
          FilledButton.icon(
            onPressed: () => setState(() => _checking = true),
            icon: const Icon(Icons.mic_rounded),
            label: const Text('Check my chord'),
          ),
      ]),
    );
  }
}

class _ChordChecker extends StatefulWidget {
  const _ChordChecker({required this.chord});

  final Chord chord;

  @override
  State<_ChordChecker> createState() => _ChordCheckerState();
}

class _ChordCheckerState extends State<_ChordChecker> with Listening {
  late final AppServices _services = context.read<AppServices>();
  ChordVerdict? _verdict;

  @override
  void onFrame(AnalysisFrame f) {
    if (!f.hasSound) return;
    setState(() => _verdict = _services.matcher.verify(f.peaks, widget.chord));
  }

  @override
  Widget build(BuildContext context) {
    final v = _verdict;
    final text = v == null
        ? 'Strum the chord and let it ring.'
        : v.matches
            ? 'Sounds like ${widget.chord.symbol}!'
            : 'Closest match: ${v.best.symbol}. Check each string.';
    return Column(children: [
      Text(text,
          style: TextStyle(
              fontSize: 20, fontWeight: FontWeight.w800, color: v == null ? null : (v.matches ? kSuccess : kAccent))),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(
          value: v?.score ?? 0,
          minHeight: 12,
          color: (v?.matches ?? false) ? kSuccess : kAccent,
          backgroundColor: kSurfaceHigh,
        ),
      ),
      const SizedBox(height: 14),
      const ListeningBadge(),
    ]);
  }
}
