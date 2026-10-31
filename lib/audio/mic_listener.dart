import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'analysis.dart';
import 'synth.dart';

enum MicStatus { idle, starting, listening, denied, error }

/// Shared microphone: screens [acquire] it while they need to listen and [release] it after,
/// so the mic only runs while something is listening. Frames arrive on [frames].
class MicListener extends ChangeNotifier {
  MicListener({double sensitivity = 0.5}) {
    this.sensitivity = sensitivity;
  }

  static const sampleRate = 44100;

  final _frames = StreamController<AnalysisFrame>.broadcast();
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _sub;
  AudioAnalyzer _analyzer = AudioAnalyzer(sampleRate: sampleRate);
  int _users = 0;
  final _pcm = Pcm16Decoder();
  DateTime _suppressUntil = DateTime.fromMillisecondsSinceEpoch(0);
  double _gate = 0.01;

  MicStatus status = MicStatus.idle;
  String? errorMessage;

  /// Smoothed input level 0..1 for meters.
  double level = 0;

  // A take being recorded: the mic's raw samples, as they come.
  IOSink? _take;
  String? _takePath;
  int _takeBytes = 0;

  /// Whether a take is being recorded.
  bool get recording => _take != null;

  Stream<AnalysisFrame> get frames => _frames.stream;

  /// Maps 0..1 sensitivity to the loudness gate: 0 needs strong playing, 1 hears soft playing.
  set sensitivity(double s) {
    _gate = 0.03 * (1 - s) + 0.003 * s;
    _analyzer.gate = _gate;
  }

  Future<void> acquire() async {
    _users++;
    if (_users == 1) await _serial(_start);
  }

  Future<void> release() async {
    if (_users == 0) return;
    _users--;
    if (_users == 0) await _serial(_stop);
  }

  /// Retry after the user granted permission in system settings.
  Future<void> retry() async {
    if (_users > 0 && status != MicStatus.listening) await _serial(_start);
  }

  // Starts and stops run one at a time, and each does nothing if [_users] no longer wants it.
  // Otherwise a quick acquire, release, acquire (switching tabs) runs two starts at once and
  // leaks the first stream.
  Future<void> _lifecycle = Future.value();

  Future<void> _serial(Future<void> Function() op) {
    final next = _lifecycle.then((_) => op());
    _lifecycle = next.catchError((Object _) {});
    return next;
  }

  /// Ignore input for [d], e.g. while the app itself plays a reference sound.
  void suppress(Duration d) {
    final until = DateTime.now().add(d);
    if (until.isAfter(_suppressUntil)) _suppressUntil = until;
  }

  Future<void> _start() async {
    if (_users == 0 || _sub != null) return;
    status = MicStatus.starting;
    errorMessage = null;
    notifyListeners();
    try {
      final recorder = _recorder ??= AudioRecorder();
      if (!await recorder.hasPermission()) {
        status = MicStatus.denied;
        notifyListeners();
        return;
      }
      _analyzer = AudioAnalyzer(sampleRate: sampleRate, gate: _gate);
      _pcm.reset();
      final stream = await recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        // Music, not speech: no echo cancelling, noise suppression or auto gain.
        androidConfig: AndroidRecordConfig(audioSource: AndroidAudioSource.voiceRecognition),
        iosConfig: IosRecordConfig(categoryOptions: [
          IosAudioCategoryOption.defaultToSpeaker,
          IosAudioCategoryOption.allowBluetoothA2DP,
          IosAudioCategoryOption.mixWithOthers,
        ]),
      ));
      if (_users == 0) {
        await recorder.stop();
        return;
      }
      _sub = stream.listen(_onBytes, onError: (Object e) {
        status = MicStatus.error;
        errorMessage = '$e';
        notifyListeners();
      });
      status = MicStatus.listening;
    } catch (e) {
      status = MicStatus.error;
      errorMessage = '$e';
    }
    notifyListeners();
  }

  /// Records what the mic hears (while something listens) into a WAV file at [path], until
  /// [stopTake]. Everything is kept, the app's own sounds included: it's the learner's take.
  Future<void> startTake(String path) async {
    await stopTake();
    await File(path).parent.create(recursive: true);
    _takePath = path;
    _takeBytes = 0;
    _take = File('$path.pcm').openWrite();
    notifyListeners();
  }

  /// Stops recording and finishes the WAV file; returns its length, or null when nothing was
  /// being recorded.
  Future<Duration?> stopTake() async {
    final sink = _take, path = _takePath;
    if (sink == null || path == null) return null;
    _take = null;
    _takePath = null;
    final bytes = _takeBytes;
    await sink.close();
    // The header needs the length, known only now: write it, then the samples after it.
    final raw = File('$path.pcm');
    final wav = File(path).openWrite()..add(pcm16WavHeader(bytes ~/ 2, sampleRate));
    await wav.addStream(raw.openRead());
    await wav.close();
    await raw.delete();
    notifyListeners();
    return Duration(microseconds: (bytes ~/ 2) * 1000000 ~/ sampleRate);
  }

  Future<void> _stop() async {
    if (_users > 0) return;
    // Nothing more to record: finish a take left running.
    await stopTake();
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder?.stop();
    } catch (_) {}
    status = MicStatus.idle;
    level = 0;
    notifyListeners();
  }

  /// What the mic would pass on as it hears [bytes] (16-bit samples), for tests.
  @visibleForTesting
  void hearBytes(Uint8List bytes) => _onBytes(bytes);

  void _onBytes(Uint8List bytes) {
    if (_take case final take?) {
      take.add(bytes);
      _takeBytes += bytes.length;
    }
    final samples = _pcm.decode(bytes);
    final suppressed = DateTime.now().isBefore(_suppressUntil);
    for (final frame in _analyzer.add(samples)) {
      level = level * 0.6 + (frame.rms * 8).clamp(0.0, 1.0) * 0.4;
      if (!suppressed) _frames.add(frame);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _recorder?.dispose();
    _frames.close();
    super.dispose();
  }
}
