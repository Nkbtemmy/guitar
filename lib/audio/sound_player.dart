import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../curriculum/models.dart';
import '../music/chord.dart';
import '../music/chord_library.dart';
import '../music/notes.dart';
import '../practice/trackers.dart';
import 'synth.dart';

/// Plays synthesized guitar sounds. Rendered clips are cached as WAV files (data URIs on web).
class SoundPlayer {
  SoundPlayer({GuitarSynth? synth, this.onReferenceSound}) : synth = synth ?? GuitarSynth();

  final GuitarSynth synth;

  /// Called with the clip length whenever a reference sound (not a metronome) starts, so the
  /// microphone can ignore the app's own audio.
  final void Function(Duration length)? onReferenceSound;

  // Created on first use so constructing the player never touches the platform.
  AudioPlayer? _soundsPlayer, _clicksPlayer;
  AudioPlayer get _sounds => _soundsPlayer ??= AudioPlayer();
  AudioPlayer get _clicks => _clicksPlayer ??= AudioPlayer();
  final _cache = <String, Source>{};
  final _lengths = <String, Duration>{};
  Directory? _dir;

  /// Lets playback and recording share the iOS audio session, routed to the speaker.
  static Future<void> configureAudioSession() async {
    if (kIsWeb) return;
    await AudioPlayer.global.setAudioContext(AudioContext(
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playAndRecord,
        options: const {
          AVAudioSessionOptions.defaultToSpeaker,
          AVAudioSessionOptions.allowBluetoothA2DP,
          AVAudioSessionOptions.mixWithOthers,
        },
      ),
      android: const AudioContextAndroid(),
    ));
  }

  Future<Duration> playChord(Chord chord, {bool slow = false}) => _play(
        slow ? 'arp:${chord.id}' : 'chord:${chord.id}',
        () => slow ? synth.arpeggio(chord.midiNotes) : synth.strum(chord.midiNotes),
      );

  Future<Duration> playNote(int midi) => _play('note:$midi', () => synth.pluck(midiToFreq(midi), seconds: 2.5));

  /// Count-in bar plus [bars] bars of clicks. Not reported as a reference sound: the mic keeps
  /// listening, and clicks are designed not to register as playing.
  Future<Duration> playClickTrack({required int bpm, required int beatsPerBar, required int bars}) => _play(
        'click:$bpm:$beatsPerBar:$bars',
        () => synth.clickTrack(bpm: bpm, beatsPerBar: beatsPerBar, bars: bars),
        player: _clicks,
        volume: 0.5,
        reference: false,
      );

  /// A strummed demo of a song or exercise: one chord per bar, following the strum pattern.
  Future<Duration> playProgression({
    required String key,
    required List<String> barChords,
    required String pattern,
    required int beatsPerBar,
    required int bpm,
    required ChordLibrary library,
  }) =>
      _play('demo:$key:$bpm', () {
        final beat = 60 / bpm * synth.sampleRate;
        final hits = StrumPattern(pattern, beatsPerBar).hits;
        final out = Float32List((beat * beatsPerBar * barChords.length + synth.sampleRate * 2).round());
        for (var b = 0; b < barChords.length; b++) {
          final notes = library.byId(barChords[b]).midiNotes;
          for (final hit in hits) {
            final eighth = hit.eighth;
            final down = hit.direction == StrumDirection.down;
            final start = ((b * beatsPerBar + eighth / 2) * beat).round();
            // Up-strums mostly catch the higher strings.
            synth.addStrum(out, start, down ? notes : notes.sublist(notes.length ~/ 2),
                down: down, seed: b * 16 + eighth, gain: down ? 0.6 : 0.4);
          }
        }
        GuitarSynth.normalize(out);
        return out;
      });

  Future<void> stop() async {
    await _soundsPlayer?.stop();
    await _clicksPlayer?.stop();
  }

  Future<Duration> _play(String key, Float32List Function() render,
      {AudioPlayer? player, double volume = 1.0, bool reference = true}) async {
    final p = player ?? _sounds;
    final source = _cache[key] ?? await _render(key, render);
    final length = _lengths[key]!;
    await p.stop();
    await p.setVolume(volume);
    if (reference) onReferenceSound?.call(length);
    await p.play(source);
    return length;
  }

  Future<Source> _render(String key, Float32List Function() render) async {
    final samples = render();
    final wav = synth.toWav(samples);
    _lengths[key] = Duration(microseconds: samples.length * 1000000 ~/ synth.sampleRate);
    final Source source;
    if (kIsWeb) {
      source = UrlSource('data:audio/wav;base64,${base64Encode(wav)}');
    } else {
      _dir ??= await getTemporaryDirectory();
      final file = File('${_dir!.path}/fretwise_${key.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}.wav');
      await file.writeAsBytes(wav, flush: true);
      source = DeviceFileSource(file.path, mimeType: 'audio/wav');
    }
    return _cache[key] = source;
  }

  void dispose() {
    _soundsPlayer?.dispose();
    _clicksPlayer?.dispose();
  }
}

extension SongDemo on SoundPlayer {
  Future<Duration> playSong(Song song, ChordLibrary library, {int? bpm}) => playProgression(
        key: song.id,
        barChords: song.bars,
        pattern: song.pattern,
        beatsPerBar: song.beatsPerBar,
        bpm: bpm ?? song.bpm,
        library: library,
      );
}
