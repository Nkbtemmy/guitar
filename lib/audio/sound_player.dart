import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../music/chord.dart';
import '../music/chord_library.dart';
import '../music/notes.dart';
import '../practice/trackers.dart';
import '../sheets/tab_sequence.dart';
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
  final _cache = <String, Future<_Clip>>{};
  Future<Directory>? _dir; // one future, so two first plays don't both clear the directory

  // Bumped by every play request and by [stop]: a request overtaken while it was rendering
  // doesn't play.
  int _latest = 0;

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

  /// All six open strings strummed slowly, low E to high e: the opening sound.
  Future<Duration> playOpenStrings() => _play(
      'open', () => synth.strum([for (var s = 6; s >= 1; s--) midiAt(s, 0)], seconds: 3.5, spreadMs: 70));

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

  /// Metronome clicks, a bar at each tempo in [barBpms] (a speed trainer steps them up), beat 1
  /// of each bar accented. Streamed like a song, so minutes of it cost little memory. Not a
  /// reference sound: the mic keeps listening.
  Future<Duration> playMetronome({required List<int> barBpms, required int beatsPerBar}) => _playTrack(
      'metronome:$beatsPerBar:${barBpms.length}:${Object.hashAll(barBpms)}', _metronomeJob(synth, barBpms, beatsPerBar),
      reference: false);

  /// A strummed demo of a song or exercise: one chord per bar, following [strum].
  Future<Duration> playProgression({
    required String key,
    required List<String> barChords,
    required StrumPattern strum,
    required int bpm,
    required ChordLibrary library,
  }) =>
      _playTrack('demo:$key:$bpm:${strum.key}',
          _barsJob(synth, [for (final id in barChords) library.byId(id)], strum, bpm));

  /// Like [playProgression], for chords that may not be in the library (song sheets).
  Future<Duration> playChords({
    required String key,
    required List<Chord> bars,
    required StrumPattern strum,
    required int bpm,
  }) =>
      _playTrack('chords:$key:$bpm:${strum.key}', _barsJob(synth, bars, strum, bpm));

  /// The play-along track: a count-in bar of clicks, then [bars] strummed with [strum] (one
  /// chord a bar) and a quiet click on every beat. Not reported as a reference sound, so the mic
  /// keeps listening; with headphones it hears only the player.
  Future<Duration> playAlongTrack({
    required String key,
    required List<Chord> bars,
    required StrumPattern strum,
    required int bpm,
  }) =>
      _playTrack('along:$key:$bpm:${strum.key}', _barsJob(synth, bars, strum, bpm, countIn: true, clicks: true),
          reference: false);

  /// Plays tab events [from]..[to] at [bpm]. Each note rings until its string is picked again.
  /// [countIn] puts a bar of clicks first; [metronome] clicks on every beat. With [listening],
  /// the mic keeps listening (to check the learner playing along) instead of ignoring the tune.
  /// The frets sound in [tuning].
  Future<Duration> playTab(
    String key,
    TabSequence tab, {
    required int bpm,
    int from = 0,
    int? to,
    int beatsPerBar = 4,
    bool countIn = false,
    bool metronome = false,
    bool listening = false,
    Tuning tuning = Tuning.standard,
  }) {
    final last = to ?? tab.events.length - 1;
    return _playTrack('tab:$key:$bpm:$from:$last:$countIn:$metronome:${tuning.name}',
        _tabJob(synth, tab, bpm, from, last, beatsPerBar, countIn: countIn, metronome: metronome, tuning: tuning),
        reference: !listening);
  }

  // Long tracks render on a background isolate, so their jobs are built by static functions:
  // a job made in an instance method could capture `this`, whose platform players can't be sent.
  static SynthTrack Function() _barsJob(GuitarSynth synth, List<Chord> bars, StrumPattern strum, int bpm,
          {bool countIn = false, bool clicks = false}) =>
      () => renderBars(synth, bars, strum: strum, bpm: bpm, countIn: countIn, clicks: clicks);

  static SynthTrack Function() _metronomeJob(GuitarSynth synth, List<int> barBpms, int beatsPerBar) => () {
        final sr = synth.sampleRate;
        final clicks = <(int, bool)>[];
        var t = 0.0;
        for (final bpm in barBpms) {
          for (var b = 0; b < beatsPerBar; b++) {
            clicks.add(((t * sr).round(), b == 0));
            t += 60 / bpm;
          }
        }
        final out = SynthTrack(synth, ((t + 0.2) * sr).round());
        for (final (at, accent) in clicks) {
          out.addClick(at, accent: accent);
        }
        return out;
      };

  static SynthTrack Function() _tabJob(
          GuitarSynth synth, TabSequence tab, int bpm, int from, int last, int beatsPerBar,
          {required bool countIn, required bool metronome, required Tuning tuning}) =>
      () => renderTab(synth, tab,
          bpm: bpm, from: from, last: last, beatsPerBar: beatsPerBar, countIn: countIn, metronome: metronome, tuning: tuning);

  /// Strums one chord a bar. A string rings until it's struck again, or until the next chord
  /// frets it differently (the hand lifts off), so old notes don't ring on under new chords and
  /// each note is synthesized only while it sounds: the cost grows with the song's length, not
  /// with its length squared. Accented strums are played louder, and a muted strum (a chuck)
  /// strikes the strings and stops them at once.
  @visibleForTesting
  static SynthTrack renderBars(GuitarSynth synth, List<Chord> bars,
      {required StrumPattern strum, required int bpm, bool countIn = false, bool clicks = false}) {
    final beatsPerBar = strum.beatsPerBar;
    final beat = 60 / bpm * synth.sampleRate;
    final lead = countIn ? beatsPerBar : 0;
    final hits = strum.hits;
    final chuck = (0.025 * synth.sampleRate).round();
    final out = SynthTrack(synth, (beat * beatsPerBar * bars.length + beat * lead + synth.sampleRate * 2).round());
    final spread = synth.strumSpread();
    // Walking backwards, stopAt[s] is the sample where string s's note must end.
    final stopAt = List<int?>.filled(7, null);
    for (var b = bars.length - 1; b >= 0; b--) {
      final frets = bars[b].frets;
      final notes = bars[b].midiNotes;
      final strings = [for (var i = 0; i < 6; i++) if (frets[i] >= 0) 6 - i]; // matches notes, low to high
      for (final hit in hits.reversed) {
        final down = hit.direction == StrumDirection.down;
        final start = ((lead + b * beatsPerBar + strum.beatOf(hit.slot)) * beat).round();
        // Up-strums mostly catch the higher strings, and strike the highest first.
        final from = down ? 0 : notes.length ~/ 2;
        final lengths = <int?>[];
        for (var k = from; k < notes.length; k++) {
          final struck = start + (down ? k - from : notes.length - 1 - k) * spread;
          final stop = stopAt[strings[k]];
          var length = stop == null ? null : stop - struck;
          if (hit.muted) length = math.min(chuck, length ?? chuck);
          lengths.add(length);
          stopAt[strings[k]] = struck;
        }
        final gain = (hit.muted ? 0.5 : (down ? 0.6 : 0.4)) * (hit.accent ? 1.5 : 1.0);
        out.addStrum(start, notes.sublist(from), down: down, seed: b * 16 + hit.slot, gain: gain, lengths: lengths);
      }
      if (b == 0) continue;
      final barStart = ((lead + b * beatsPerBar) * beat).round();
      final before = bars[b - 1].frets;
      for (var i = 0; i < 6; i++) {
        if (frets[i] != before[i]) stopAt[6 - i] = barStart;
      }
    }
    out.normalize();
    // Clicks go on after normalizing so they stay at metronome level under the guitar.
    for (var i = 0; i < lead; i++) {
      out.addClick((i * beat).round(), accent: i == 0);
    }
    if (clicks) {
      for (var i = 0; i < bars.length * beatsPerBar; i++) {
        out.addClick(((lead + i) * beat).round(), accent: i % beatsPerBar == 0);
      }
    }
    return out;
  }

  /// Tab events [from]..[last], as [playTab] plays them.
  @visibleForTesting
  static SynthTrack renderTab(GuitarSynth synth, TabSequence tab,
      {required int bpm,
      required int from,
      required int last,
      required int beatsPerBar,
      required bool countIn,
      required bool metronome,
      Tuning tuning = Tuning.standard}) {
    final sr = synth.sampleRate;
    final beat = 60 / bpm;
    final lead = countIn ? beatsPerBar * beat : 0.0;
    final length = tab.durationOf(bpm, from: from, to: last);
    final out = SynthTrack(synth, ((lead + length + 1.5) * sr).round());
    if (countIn) {
      for (var b = 0; b < beatsPerBar; b++) {
        out.addClick((b * beat * sr).round(), accent: b == 0);
      }
    }
    if (metronome) {
      for (var b = 0; b * beat < length; b++) {
        out.addClick(((lead + b * beat) * sr).round(), accent: b % beatsPerBar == 0);
      }
    }
    // Walk backwards so each note knows when its string is next picked.
    final ring = (3.0 * sr).round();
    final nextOnString = <int, int>{};
    for (var i = last; i >= from; i--) {
      final start = ((lead + tab.timeOf(i, bpm, from: from)) * sr).round();
      tab.events[i].frets.forEach((string, fret) {
        final next = nextOnString[string];
        out.addNote(start, tuning.midiAt(string, fret),
            gain: 0.6, seed: i * 7 + string, lengthSamples: next == null ? ring : math.min(ring, next - start));
        nextOnString[string] = start;
      });
    }
    out.normalize();
    return out;
  }

  Future<void> stop() async {
    _latest++;
    await _soundsPlayer?.stop();
    await _clicksPlayer?.stop();
  }

  /// A short clip (a chord, a note), rendered in place.
  Future<Duration> _play(String key, Float32List Function() render,
          {AudioPlayer? player, double volume = 1.0, bool reference = true}) =>
      _playClip(key, () => _save(key, synth.toWav(render())), player: player, volume: volume, reference: reference);

  /// A long track (a song, a tab): synthesized on a background isolate a block at a time,
  /// straight into its file, so the UI keeps drawing and memory stays small however long it is.
  Future<Duration> _playTrack(String key, SynthTrack Function() build, {bool reference = true}) =>
      _playClip(key, () async {
        // No isolates or files on the web.
        if (kIsWeb) return _save(key, synth.toWav(build().renderAll()));
        final path = await _pathFor(key);
        final samples = await compute(_writeTrack, (build: build, path: path));
        return (source: DeviceFileSource(path, mimeType: 'audio/wav'), length: _duration(samples));
      }, reference: reference);

  /// Plays a clip, making it the first time. Returns its length, or zero when it didn't play:
  /// stopped or overtaken by another request while it was being made, or the platform failed.
  Future<Duration> _playClip(String key, Future<_Clip> Function() make,
      {AudioPlayer? player, double volume = 1.0, bool reference = true}) async {
    final request = ++_latest;
    final clip = await (_cache[key] ??= make().catchError((Object e, StackTrace s) {
      _cache.remove(key); // let the next request try again
      Error.throwWithStackTrace(e, s);
    }));
    if (request != _latest) return Duration.zero;
    final p = player ?? _sounds;
    try {
      await p.stop();
      await p.setVolume(volume);
      if (reference) onReferenceSound?.call(clip.length);
      await p.play(clip.source);
    } on Exception catch (e) {
      // A sound that can't play (no audio focus, output busy) mustn't break the screen that asked.
      debugPrint('SoundPlayer: $key failed to play: $e');
      return Duration.zero;
    }
    return clip.length;
  }

  Future<_Clip> _save(String key, Uint8List wav) async {
    final length = _duration((wav.length - 44) ~/ 2);
    if (kIsWeb) return (source: UrlSource('data:audio/wav;base64,${base64Encode(wav)}'), length: length);
    final file = File(await _pathFor(key));
    await file.writeAsBytes(wav, flush: true);
    return (source: DeviceFileSource(file.path, mimeType: 'audio/wav'), length: length);
  }

  Future<String> _pathFor(String key) async {
    final dir = await (_dir ??= _cleanDirectory());
    return '${dir.path}/guitaro_${key.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}.wav';
  }

  /// The temporary directory, cleared of earlier runs' clips: they're never reused (the cache
  /// lives in memory), and a song track can run to tens of megabytes.
  static Future<Directory> _cleanDirectory() async {
    final dir = await getTemporaryDirectory();
    try {
      await for (final f in dir.list()) {
        final name = f.uri.pathSegments.last;
        if (f is File && name.startsWith('guitaro_') && name.endsWith('.wav')) await f.delete();
      }
    } on FileSystemException catch (e) {
      debugPrint('SoundPlayer: could not clear old clips: $e');
    }
    return dir;
  }

  Duration _duration(int samples) => Duration(microseconds: samples * 1000000 ~/ synth.sampleRate);

  void dispose() {
    _soundsPlayer?.dispose();
    _clicksPlayer?.dispose();
  }
}

typedef _Clip = ({Source source, Duration length});

/// Synthesizes a track into a WAV file at [path], a block at a time. Runs on a background
/// isolate; returns the length in samples.
int _writeTrack(({SynthTrack Function() build, String path}) job) {
  final track = job.build();
  final file = File(job.path).openSync(mode: FileMode.write);
  try {
    file.writeFromSync(track.synth.wavHeader(track.length));
    track.render((block) => file.writeFromSync(track.synth.pcm16(block)));
  } finally {
    file.closeSync();
  }
  return track.length;
}
