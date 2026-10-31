import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'analysis.dart';

enum PlaybackStatus { idle, starting, listening, denied, error }

/// Listens to the sound the app itself is playing (a YouTube video in the app), on Android 10
/// and up, through the system's playback capture. The user approves it in a system dialog each
/// time; the capture runs in a foreground service while [status] is listening. Frames arrive
/// on [frames] like the mic's.
class PlaybackListener extends ChangeNotifier {
  static const sampleRate = 44100;
  static const _channel = MethodChannel('guitaro/playback_capture');
  static const _pcm = EventChannel('guitaro/playback_capture/pcm');

  final _frames = StreamController<AnalysisFrame>.broadcast();
  final _decoder = Pcm16Decoder();
  // The signal is clean (no room noise), so hear quiet passages too.
  AudioAnalyzer _analyzer = AudioAnalyzer(sampleRate: sampleRate, gate: 0.003);
  StreamSubscription<dynamic>? _sub;

  PlaybackStatus status = PlaybackStatus.idle;
  String? errorMessage;

  /// Smoothed level 0..1 for meters.
  double level = 0;

  Stream<AnalysisFrame> get frames => _frames.stream;

  /// Whether this device can capture its own playback (Android 10+).
  static Future<bool> isSupported() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Asks the user, then starts capturing. Resolves once sound is flowing or the request was
  /// turned down; check [status].
  Future<void> start() async {
    if (status == PlaybackStatus.starting || status == PlaybackStatus.listening) return;
    status = PlaybackStatus.starting;
    errorMessage = null;
    notifyListeners();
    try {
      // Playback capture goes through the same recording permission as the mic. Each recorder
      // holds a native one until disposed.
      final recorder = AudioRecorder();
      final allowed = await recorder.hasPermission().whenComplete(recorder.dispose);
      if (!allowed) {
        status = PlaybackStatus.denied;
        notifyListeners();
        return;
      }
      _analyzer = AudioAnalyzer(sampleRate: sampleRate, gate: 0.003);
      _decoder.reset();
      _sub = _pcm.receiveBroadcastStream().listen(_onBytes, onError: (Object e) {
        status = PlaybackStatus.error;
        errorMessage = e is PlatformException ? (e.message ?? e.code) : '$e';
        notifyListeners();
      }, onDone: () {
        // The system (or the user, from the status bar) ended the capture.
        if (status == PlaybackStatus.listening) status = PlaybackStatus.idle;
        level = 0;
        notifyListeners();
      });
      await _channel.invokeMethod<void>('start');
      // Disposed while the user was answering the system dialog: don't leave a capture running.
      if (_disposed) {
        await stop();
        return;
      }
      status = PlaybackStatus.listening;
    } on PlatformException catch (e) {
      await _sub?.cancel();
      _sub = null;
      status = e.code == 'denied' ? PlaybackStatus.denied : PlaybackStatus.error;
      errorMessage = e.message ?? e.code;
    } catch (e) {
      await _sub?.cancel();
      _sub = null;
      status = PlaybackStatus.error;
      errorMessage = '$e';
    }
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
    if (status != PlaybackStatus.idle) {
      status = PlaybackStatus.idle;
      level = 0;
      notifyListeners();
    }
  }

  void _onBytes(dynamic data) {
    if (data is! Uint8List) return;
    for (final frame in _analyzer.add(_decoder.decode(data))) {
      level = level * 0.6 + (frame.rms * 8).clamp(0.0, 1.0) * 0.4;
      _frames.add(frame);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    _frames.close();
    super.dispose();
  }
}
