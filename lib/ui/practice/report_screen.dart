import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app_services.dart';
import '../../practice/report.dart';
import '../../progress/practice_log.dart';
import '../../progress/progress_store.dart';
import '../theme.dart';

/// A progress report to send a teacher or a parent: the course, practice time, chord changes,
/// best scores, homework and what to work on next, as text for any chat app.
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  late final _name = TextEditingController(text: context.read<ProgressStore>().studentName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _share(String report) async {
    try {
      await SharePlus.instance.share(ShareParams(text: report, subject: 'Guitaro progress'));
    } on Exception catch (e) {
      debugPrint('Report: could not share: $e');
      await _copy(report);
    }
  }

  Future<void> _copy(String report) async {
    await Clipboard.setData(ClipboardData(text: report));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied: paste it into a message.')));
  }

  @override
  Widget build(BuildContext context) {
    final report = progressReport(
      name: _name.text,
      progress: context.watch<ProgressStore>(),
      log: context.watch<PracticeLog>(),
      curriculum: context.read<AppServices>().curriculum,
      now: DateTime.now(),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Progress report')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: "Student's name", border: OutlineInputBorder()),
            onChanged: (v) {
              context.read<ProgressStore>().studentName = v;
              setState(() {});
            },
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(report, style: const TextStyle(height: 1.5)),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: () => _share(report), icon: const Icon(Icons.share_rounded), label: const Text('Send to teacher or parent')),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: () => _copy(report), icon: const Icon(Icons.copy_rounded), label: const Text('Copy')),
          const SizedBox(height: 12),
          const Text('Nothing is sent unless you send it.', textAlign: TextAlign.center, style: TextStyle(color: kMuted, fontSize: 13)),
        ]),
      ),
    );
  }
}
