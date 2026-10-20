import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'analysis.dart';

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
  int _leftoverByte = -1;
  DateTime _suppressUntil = DateTime.fromMillisecondsSinceEpoch(0);
  double _gate = 0.01;

  MicStatus status = MicStatus.idle;
  String? errorMessage;

  /// Smoothed input level 0..1 for meters.
  double level = 0;

  Stream<AnalysisFrame> get frames => _frames.stream;

  /// Maps 0..1 sensitivity to the loudness gate: 0 needs strong playing, 1 hears soft playing.
  set sensitivity(double s) {
    _gate = 0.03 * (1 - s) + 0.003 * s;
    _analyzer.gate = _gate;
  }

  Future<void> acquire() async {
    _users++;
    if (_users == 1) await _start();
  }

  Future<void> release() async {
    if (_users == 0) return;
    _users--;
    if (_users == 0) await _stop();
  }

  /// Retry after the user granted permission in system settings.
  Future<void> retry() async {
    if (_users > 0 && status != MicStatus.listening) await _start();
  }

  /// Ignore input for [d], e.g. while the app itself plays a reference sound.
  void suppress(Duration d) {
    final until = DateTime.now().add(d);
    if (until.isAfter(_suppressUntil)) _suppressUntil = until;
  }

  Future<void> _start() async {
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
      _leftoverByte = -1;
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

  Future<void> _stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder?.stop();
    } catch (_) {}
    status = MicStatus.idle;
    level = 0;
    notifyListeners();
  }

  void _onBytes(Uint8List bytes) {
    var start = 0;
    final samples = Float32List((bytes.length + (_leftoverByte >= 0 ? 1 : 0)) ~/ 2);
    var n = 0;
    if (_leftoverByte >= 0 && bytes.isNotEmpty) {
      samples[n++] = ((bytes[0] << 8 | _leftoverByte).toSigned(16)) / 32768;
      start = 1;
      _leftoverByte = -1;
    }
    for (var i = start; i + 1 < bytes.length; i += 2) {
      samples[n++] = ((bytes[i + 1] << 8 | bytes[i]).toSigned(16)) / 32768;
    }
    if ((bytes.length - start).isOdd) _leftoverByte = bytes.last;

    final suppressed = DateTime.now().isBefore(_suppressUntil);
    for (final frame in _analyzer.add(Float32List.sublistView(samples, 0, n))) {
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
