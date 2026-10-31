import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../audio/mic_listener.dart';
import '../progress/practice_log.dart';

/// Recordings of the learner: where their files live, and making and removing them. They stay on
/// the device (the app's own documents folder) and are never uploaded.
abstract final class Takes {
  @visibleForTesting
  static Directory? directoryForTests;

  /// Shorter than this, it was a slip of the finger: not kept.
  static const shortest = Duration(seconds: 2);

  static Future<Directory> directory() async =>
      directoryForTests ?? Directory('${(await getApplicationDocumentsDirectory()).path}/takes');

  static Future<File> fileOf(String id) async => File('${(await directory()).path}/$id.wav');

  /// Starts recording on [mic]; returns the new take's id.
  static Future<String> start(MicListener mic, {DateTime? now}) async {
    final id = 'take_${(now ?? DateTime.now()).millisecondsSinceEpoch}';
    await mic.startTake((await fileOf(id)).path);
    return id;
  }

  /// Finishes take [id] and keeps it in [log] as [title]. Null when it was too short to keep.
  static Future<Take?> finish(MicListener mic, PracticeLog log, String id, {required String title, String note = ''}) async {
    final length = await mic.stopTake();
    if (length == null) return null;
    if (length < shortest) {
      await _deleteFile(id);
      return null;
    }
    final take = Take(id: id, title: title, created: DateTime.now(), seconds: length.inMilliseconds / 1000, note: note);
    log.addTake(take);
    return take;
  }

  static Future<void> delete(PracticeLog log, Take take) async {
    log.removeTake(take);
    await _deleteFile(take.id);
  }

  static Future<void> _deleteFile(String id) async {
    try {
      await (await fileOf(id)).delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}
