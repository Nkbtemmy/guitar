import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guitaro/app_services.dart';
import 'package:guitaro/audio/analysis.dart';
import 'package:guitaro/audio/sound_player.dart';
import 'package:guitaro/audio/synth.dart';
import 'package:guitaro/curriculum/models.dart';
import 'package:guitaro/main.dart';
import 'package:guitaro/music/chord_library.dart';
import 'package:guitaro/music/notes.dart';
import 'package:guitaro/progress/progress_store.dart';
import 'package:guitaro/sheets/chord_finder.dart';
import 'package:guitaro/sheets/chord_resolver.dart';
import 'package:guitaro/sheets/chord_sheet.dart';
import 'package:guitaro/sheets/chord_symbol.dart';
import 'package:guitaro/sheets/sheet_song.dart';
import 'package:guitaro/sheets/songbook_store.dart';
import 'package:guitaro/sheets/tab_sequence.dart';
import 'package:guitaro/ui/practice/song_view.dart';
import 'package:guitaro/ui/sheets/sheet_body.dart';
import 'package:guitaro/ui/sheets/tab_player.dart';
import 'package:guitaro/ui/songs/songs_screen.dart';
import 'package:guitaro/ui/splash_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show FakeMic;

final library = ChordLibrary.fromJson(
  File('assets/data/chords.json').readAsStringSync(),
  tipsJson: File('assets/data/chord_tips.json').readAsStringSync(),
);
final resolver = ChordResolver(library);

List<ChordSheet> bundledSheets() => [
      for (final f in Directory('assets/songs').listSync().whereType<File>().where((f) => f.path.endsWith('.cho')))
        ChordSheet.parse(f.readAsStringSync(), id: AppServices.sheetIdForAsset(f.path)),
    ];

/// Note names a tab plays, e.g. ["E4", "D#4"]; chords as "A2+E3".
List<String> notesOf(TabSequence tab) => [for (final e in tab.events) e.midiNotes.map(noteNameWithOctave).join('+')];

void main() {
  group('chord symbols', () {
    test('parse root, quality and bass', () {
      final s = ChordSymbol.tryParse('C#m7/G#')!;
      expect(s.root, 1);
      expect(s.quality, ChordQuality.min7);
      expect(s.bass, 8);
      expect(ChordSymbol.tryParse('Bbmaj7')!.quality, ChordQuality.maj7);
      expect(ChordSymbol.tryParse('Asus')!.quality, ChordQuality.sus4);
      for (final word in ['x2', '|', 'the', 'Amazing', 'H', '']) {
        expect(ChordSymbol.tryParse(word), isNull, reason: word);
      }
    });

    test('transpose with common spellings', () {
      expect(transposeName('G', 2), 'A');
      expect(transposeName('A', 1), 'Bb');
      expect(transposeName('Em', 4), 'G#m');
      expect(transposeName('F#', -1), 'F');
      expect(transposeName('D/F#', 2), 'E/G#');
      expect(transposeName('Am7', 3), 'Cm7');
      expect(transposeName('Bb', 0), 'Bb', reason: 'unshifted chords keep their spelling');
      expect(transposeName('x2', 5), 'x2');
      expect(transposeName('C', 12), 'C');
    });
  });

  group('voicings', () {
    const intervals = <ChordQuality, Set<int>>{
      ChordQuality.major: {0, 4, 7},
      ChordQuality.minor: {0, 3, 7},
      ChordQuality.dom7: {0, 4, 7, 10},
      ChordQuality.min7: {0, 3, 7, 10},
      ChordQuality.maj7: {0, 4, 7, 11},
      ChordQuality.sus2: {0, 2, 7},
      ChordQuality.sus4: {0, 5, 7},
      ChordQuality.dom7sus4: {0, 5, 7, 10},
      ChordQuality.add9: {0, 2, 4, 7},
      ChordQuality.dom9: {0, 2, 4, 7, 10},
      ChordQuality.six: {0, 4, 7, 9},
      ChordQuality.min6: {0, 3, 7, 9},
      ChordQuality.power: {0, 7},
      ChordQuality.dim: {0, 3, 6},
      ChordQuality.dim7: {0, 3, 6, 9},
      ChordQuality.halfDim: {0, 3, 6, 10},
      ChordQuality.aug: {0, 4, 8},
    };

    test('every generated shape spells its chord, on every root', () {
      for (final MapEntry(key: quality, value: want) in intervals.entries) {
        for (var root = 0; root < 12; root++) {
          final c = ChordResolver.generate(root, quality)!;
          final where = '${c.symbol} ${c.frets}';
          expect(c.pitchClasses, {for (final i in want) (root + i) % 12}, reason: where);
          expect(c.frets.every((f) => f <= 15), isTrue, reason: where);
          for (var i = 0; i < 6; i++) {
            if (c.frets[i] > 0) expect(c.fingers[i], inInclusiveRange(1, 4), reason: where);
          }
        }
      }
    });

    test('library shapes come first, anything else is generated', () {
      expect(resolver.resolve('G')!.id, 'G');
      expect(resolver.resolve('A#')!.id, 'Bb');
      final eb = resolver.resolve('Eb')!;
      expect(eb.pitchClasses, {3, 7, 10});
      expect(eb.barre, isNotNull);
      expect(resolver.resolve('Gmaj9')!.pitchClasses, {7, 11, 2, 6}, reason: 'voiced as maj7');
      expect(resolver.resolve('D/F#')!.id, 'D');
      expect(resolver.resolve('lyric'), isNull);
    });

    test('simplify drops extensions and avoids barres where it can', () {
      expect(resolver.resolve('Am7', simplify: true)!.id, 'Am');
      expect(resolver.resolve('Cmaj7', simplify: true)!.id, 'C');
      expect(resolver.resolve('F', simplify: true)!.id, 'Fmaj7');
      expect(resolver.resolve('B', simplify: true)!.id, 'B7');
      expect(resolver.resolve('Bm', simplify: true)!.id, 'Bm', reason: 'nothing easier holds B, D and F#');
    });

    test('capo suggestion finds easier shapes', () {
      expect(resolver.suggestCapo(['G', 'C', 'D', 'Em']), 0);
      // Canon in D: capo 2 turns D A Bm F#m G into C G Am Em F.
      expect(resolver.suggestCapo(['D', 'A', 'Bm', 'F#m', 'G']), 2);
      final eb = resolver.suggestCapo(['Eb', 'Bb', 'Cm', 'Ab']);
      expect(eb, isNot(0));
      expect(
        resolver.effort(['Eb', 'Bb', 'Cm', 'Ab'].map((n) => transposeName(n, -eb))),
        lessThan(resolver.effort(['Eb', 'Bb', 'Cm', 'Ab'])),
      );
    });
  });

  group('ChordPro', () {
    const source = '''
{title: Test Song}
{artist: Someone}
{key: G}
{capo: 2}
{tempo: 96}
{time: 3/4}
{difficulty: beginner}
{tags: folk, test}

{start_of_verse: Verse 1}
A[G]mazing [C]grace, how sweet the [G]sound
[Em]   [D]

{start_of_chorus}
[C]Sing it [G]out
{end_of_chorus}

{comment: Softly now}
{chorus}

{start_of_tab: Riff}
e|-0-----|
B|---1---|
G|-----2-|
D|-------|
A|-------|
E|-------|
{end_of_tab}
''';

    test('reads metadata, chords at their syllables, sections, comments and tab', () {
      final s = ChordSheet.parse(source, id: 't');
      expect((s.title, s.artist, s.key, s.capo, s.tempo, s.beatsPerBar), ('Test Song', 'Someone', 'G', 2, 96, 3));
      expect(s.difficulty, Difficulty.beginner);
      expect(s.tags, ['folk', 'test']);
      expect(s.chordNames, ['G', 'C', 'Em', 'D']);

      final lyric = s.lines.whereType<LyricLine>().first;
      expect(lyric.text, 'Amazing grace, how sweet the sound');
      expect([for (final c in lyric.chords) (c.offset, c.name)], [(1, 'G'), (8, 'C'), (29, 'G')]);

      final sections = [for (final l in s.lines.whereType<SectionLine>()) l.label];
      expect(sections, ['Verse 1', 'Chorus', 'Chorus']);
      expect(s.lines.whereType<CommentLine>().single.text, 'Softly now');
      expect(
        s.lines.whereType<LyricLine>().where((l) => l.text == 'Sing it out').length,
        2,
        reason: '{chorus} repeats it',
      );
      final tab = s.lines.whereType<TabLines>().single;
      expect(tab.label, 'Riff');
      expect(notesOf(tab.sequence!), ['E4', 'C4', 'A3']);
    });

    test('round-trips through toChordPro', () {
      final a = ChordSheet.parse(source, id: 't');
      final b = ChordSheet.parse(a.toChordPro(), id: 't');
      expect(b.title, a.title);
      expect(b.capo, a.capo);
      expect(b.chordNames, a.chordNames);
      List<String> lyrics(ChordSheet s) => [
            for (final l in s.lines.whereType<LyricLine>()) ChordSheet.inlineChords(l.text, l.chords),
          ];
      expect(lyrics(b), lyrics(a));
      expect(b.tabs.single.events.length, 3);
    });
  });

  group('chords over lyrics', () {
    const pasted = '''
[Intro]
G   C   D

[Verse 1]
G              C          G
Write your own song or paste one here
         D               G
Chords go on the line above the words

Chorus:
Em    C
Just  lyrics with no chords
e|-----0-------|
B|---1---1-----|
G|-2-------2---|
D|-------------|
A|-------------|
E|-------------|
''';

    test('pairs chord lines with the lyric below, by column', () {
      expect(ChordSheet.looksLikeChordPro(pasted), isFalse);
      final s = ChordSheet.parse(pasted, id: 'p');
      final sections = [for (final l in s.lines.whereType<SectionLine>()) l.label];
      expect(sections, ['Intro', 'Verse 1', 'Chorus']);
      final lines = s.lines.whereType<LyricLine>().toList();
      expect(lines[0].text, '', reason: 'intro is chords only');
      expect([for (final c in lines[0].chords) c.name], ['G', 'C', 'D']);
      expect(lines[1].text, 'Write your own song or paste one here');
      expect([for (final c in lines[1].chords) (c.offset, c.name)], [(0, 'G'), (15, 'C'), (26, 'G')]);
      expect(lines[2].chords.first.offset, 9);
      expect(s.chordNames, ['G', 'C', 'D', 'Em']);
      expect(notesOf(s.tabs.single), ['A3', 'C4', 'E4', 'C4', 'A3']);
    });

    test('a row of dashes is not tab, and lyric lines are not chord lines', () {
      final s = ChordSheet.parse('A man walked by\n----------\nAm I the one', id: 'x');
      expect(s.hasTab, isFalse);
      expect(s.lines.whereType<LyricLine>().every((l) => l.chords.isEmpty), isTrue);
    });
  });

  group('tab sequence', () {
    test('two-digit frets, chords in one column, systems played in order', () {
      final tab = TabSequence.parse(
        '''
e|-12---0-|
B|-------|
G|-------|
D|-------|
A|---0---|
E|---0---|

e|-3--|
B|----|
G|----|
D|----|
A|----|
E|----|'''
            .split('\n'),
      )!;
      expect(notesOf(tab), ['E5', 'E2+A2', 'E4', 'G4']);
      // The first system is 8 sixteenths long; its closing bar line takes no time.
      expect(tab.events.map((e) => e.column), [1, 3, 6, 9]);
      // A column is a sixteenth: at 60 BPM, 0.25 s.
      expect(tab.timeOf(1, 60), closeTo(0.5, 1e-9));
      expect(tab.eventAt(0.6, 60), 1);
      expect(tab.eventAt(0.6, 60, from: 2), 2, reason: 'counts from the loop start');
      expect(tab.durationOf(60, from: 0, to: 1), closeTo(1.5, 1e-9));
    });

    test('rejects incomplete systems', () {
      expect(TabSequence.parse(['e|--0--|', 'B|--1--|']), isNull);
    });

    test('chord names over the bars, and where each bar starts', () {
      const source = '''
  E       A
e|--------|--------|
B|--------|--------|
G|--------|--------|
D|--------|2-2-4-4-|
A|2-2-4-4-|0-0-0-0-|
E|0-0-0-0-|--------|

B
e|--------|
B|--------|
G|--------|
D|4---6---|
A|2-------|
E|--------|''';
      final tab = TabSequence.parse(source.split('\n'))!;
      expect(tab.labels, ['E', null, null, null, 'A', null, null, null, 'B', null]);
      expect(tab.barStarts, [4, 8]);

      // Kept with the tab in plain and ChordPro sheets, and listed with the song's chords.
      for (final text in [source, '{title: X}\n$source']) {
        final sheet = ChordSheet.parse(text, id: 'x');
        expect(sheet.lines.whereType<LyricLine>().where((l) => l.chords.isNotEmpty), isEmpty);
        expect(sheet.chordNames, ['E', 'A', 'B']);
      }
    });
  });

  group('bundled songs', () {
    test('the shuffle riff names the chord over each of its 12 bars', () {
      final riff = bundledSheets().firstWhere((s) => s.id == 'pd:blues_shuffle_e').tabs.single;
      expect(riff.labels.nonNulls, 'E E E E A A E E B A E E'.split(' '));
      expect(riff.barStarts, hasLength(11));
    });

    final sheets = bundledSheets();

    test('there are plenty, each complete and every chord playable', () {
      expect(sheets.length, greaterThanOrEqualTo(30));
      expect(sheets.map((s) => s.id).toSet().length, sheets.length);
      for (final s in sheets) {
        expect(s.title, isNot('Untitled'), reason: s.id);
        expect(s.artist, isNotEmpty, reason: s.id);
        expect(s.key, isNotNull, reason: s.id);
        expect(s.difficulty, isNotNull, reason: s.id);
        expect(s.tempo, isNotNull, reason: s.id);
        expect(s.tags, isNotEmpty, reason: s.id);
        expect(s.chordNames.isNotEmpty || s.hasTab, isTrue, reason: s.id);
        for (final name in s.chordNames) {
          expect(resolver.resolve(name), isNotNull, reason: '${s.id}: $name');
        }
        for (final block in s.lines.whereType<TabLines>()) {
          expect(block.sequence, isNotNull, reason: '${s.id}: tab "${block.label}" did not parse');
        }
      }
    });

    test('Amazing Grace has the whole tune, in time, with its chords and all seven verses', () {
      final sheet = sheets.firstWhere((s) => s.id == 'pd:amazing_grace');
      final tab = sheet.tabs.single;
      // The hymnal melody, bar by bar in sixteenths after the one-beat pickup (3/4: 12 a bar).
      const bars = [
        [0], [0, 8, 10], [0, 8], [0, 8], [0, 8], [0, 8, 10], [0, 8], [0, 8], // A-mazing grace ... me! I
        [0, 6, 8, 10], [0, 8], [0, 6, 8, 10], [0, 8], [0, 8, 10], [0, 8], [0], // once was lost ... see.
      ];
      final columns = [
        for (var b = 0; b < bars.length; b++)
          for (final c in bars[b]) (b == 0 ? 0 : 4 + (b - 1) * 12) + c,
      ];
      expect([for (final e in tab.events) e.column - tab.events.first.column], columns);
      expect([for (final b in tab.barStarts) tab.labels[b]].nonNulls.toList(),
          ['G', 'G7', 'C', 'G', 'D', 'G', 'G7', 'C', 'G', 'Em', 'D', 'G']);
      expect([for (final l in sheet.lines) if (l is SectionLine) l.label].where((l) => l.startsWith('Verse')).length, 7);
    });

    test('melody tabs play the right notes', () {
      List<String> melody(String id) => notesOf(sheets.firstWhere((s) => s.id == id).tabs.single);
      expect(
        melody('pd:ode_to_joy'),
        'E4 E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 E4 D4 D4 E4 E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 D4 C4 C4'.split(' '),
      );
      expect(melody('pd:twinkle_twinkle').take(14), 'C4 C4 G4 G4 A4 A4 G4 F4 F4 E4 E4 D4 D4 C4'.split(' '));
      expect(
        melody('pd:greensleeves').take(19),
        'A3 C4 D4 E4 F4 E4 D4 B3 G3 A3 B3 C4 A3 A3 G#3 A3 B3 G#3 E3'.split(' '),
      );
      expect(melody('pd:fur_elise').take(9), 'E4 D#4 E4 D#4 E4 B3 D4 C4 A3'.split(' '));
      expect(
        melody('pd:amazing_grace'),
        ('D3 G3 B3 G3 B3 A3 G3 E3 D3 D3 G3 B3 G3 B3 A3 D4 B3 '
                'D4 B3 D4 B3 G3 D3 E3 G3 G3 E3 D3 D3 G3 B3 G3 B3 A3 G3')
            .split(' '),
      );
      expect(melody('pd:when_the_saints').take(8), 'G3 B3 C4 D4 G3 B3 C4 D4'.split(' '));
      expect(melody('pd:spanish_romance').take(4), ['E2+B4', 'B3', 'G3', 'B4']);
      expect(melody('pd:blues_shuffle_e').take(4), ['E2+B2', 'E2+B2', 'E2+C#3', 'E2+C#3']);
    });
  });

  group('songbook store', () {
    test('favorites, recent, setlists and own songs persist', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = SongbookStore(prefs)
        ..toggleFavorite('pd:a')
        ..toggleFavorite('pd:b')
        ..toggleFavorite('pd:a');
      expect(store.favorites, ['pd:b']);

      for (var i = 0; i < 25; i++) {
        store.markViewed('pd:$i');
      }
      store.markViewed('pd:3');
      expect(store.recent.length, SongbookStore.maxRecent);
      expect(store.recent.first, 'pd:3');

      final set = store.createSetlist('Gig');
      for (final id in ['pd:a', 'pd:b', 'pd:c', 'pd:a']) {
        store.addToSetlist(set.id, id);
      }
      expect(store.setlist(set.id)!.sheetIds, ['pd:a', 'pd:b', 'pd:c'], reason: 'no duplicates');
      store.reorderSetlist(set.id, 0, 2);
      expect(store.setlist(set.id)!.sheetIds, ['pd:b', 'pd:c', 'pd:a']);

      final mine = store.saveUserSong(const UserSong(id: '', title: 'Mine', body: 'G  C\nHello there'));
      expect(mine.id, startsWith('my:'));
      store
        ..toggleFavorite(mine.id)
        ..addToSetlist(set.id, mine.id)
        ..setPrefs(mine.id, const SheetPrefs(transpose: 3, capo: 1));

      final reloaded = SongbookStore(prefs);
      expect(reloaded.favorites, [mine.id, 'pd:b']);
      expect(reloaded.setlists.single.name, 'Gig');
      expect(reloaded.prefsFor(mine.id).transpose, 3);
      expect(reloaded.prefsFor(mine.id).capo, 1);
      final sheet = reloaded.userSong(mine.id)!.toSheet();
      expect(sheet.title, 'Mine');
      expect(sheet.chordNames, ['G', 'C']);

      reloaded.deleteUserSong(mine.id);
      expect(reloaded.favorites, ['pd:b']);
      expect(reloaded.setlists.single.sheetIds, isNot(contains(mine.id)));
    });

    test('a damaged entry is skipped, the rest still load, and the original is kept', () async {
      const good = {'id': 'my:1', 'title': 'Kept', 'body': 'G\nla', 'capo': 2.0, 'tempo': 90};
      final raw = jsonEncode({
        'favorites': ['my:1'],
        'songs': [good, {'id': 'my:2', 'title': 'No body'}, 'not a song'],
        'setlists': [{'id': 's', 'name': 'Gig', 'sheets': ['my:2', 'my:1']}, {'name': 'no id'}],
        'prefs': {'my:1': {'transpose': 1.0}, 'my:2': 'nonsense'},
      });
      SharedPreferences.setMockInitialValues({'songbook.v1': raw});
      final prefs = await SharedPreferences.getInstance();
      final store = SongbookStore(prefs);
      expect(store.userSongs.single.title, 'Kept');
      expect(store.userSongs.single.capo, 2);
      expect(store.favorites, ['my:1']);
      expect(store.setlists.single.sheetIds, ['my:2', 'my:1']);
      expect(store.prefsFor('my:1').transpose, 1);
      expect(prefs.getString('songbook.v1.damaged'), raw);
      // Not JSON at all: starts empty instead of failing to start.
      SharedPreferences.setMockInitialValues({'songbook.v1': '{oops'});
      expect(SongbookStore(await SharedPreferences.getInstance()).userSongs, isEmpty);
    });

    test('reordering the songs a setlist shows leaves the ones it can\'t show in place', () {
      final store = SongbookStore();
      final set = store.createSetlist('Gig');
      for (final id in ['pd:a', 'gone', 'pd:b', 'pd:c']) {
        store.addToSetlist(set.id, id);
      }
      // The screen shows a, b, c (it can't open "gone") and drags a to the end.
      store.arrangeSetlist(set.id, ['pd:b', 'pd:c', 'pd:a']);
      expect(store.setlist(set.id)!.sheetIds, ['pd:b', 'gone', 'pd:c', 'pd:a']);
    });
  });

  group('play along and chord finder', () {
    test('a link with broken %-escapes is not a YouTube link (and does not throw)', () {
      for (final bad in ['youtu.be/%FF', 'youtube.com/watch?v=%FF', 'https://www.youtube.com/shorts/%E0%A4']) {
        expect(youtubeUrl(bad), isNull, reason: bad);
      }
      expect(ChordSheet.parse('{youtube: youtu.be/%FF}\n[G]la', id: 'x').link, isNull);
    });

    test('out-of-range tempo, time and capo in a sheet fall back to the defaults', () {
      for (final directive in ['{tempo: 0}', '{tempo: -60}', '{tempo: 1}', '{tempo: 5000}']) {
        expect(ChordSheet.parse('$directive\n[G]la', id: 'x').tempo, isNull, reason: directive);
      }
      for (final directive in ['{time: 0/4}', '{time: -3/4}', '{time: 99/4}']) {
        expect(ChordSheet.parse('$directive\n[G]la', id: 'x').beatsPerBar, 4, reason: directive);
      }
      for (final directive in ['{capo: -2}', '{capo: 40}']) {
        expect(ChordSheet.parse('$directive\n[G]la', id: 'x').capo, 0, reason: directive);
      }
      final ok = ChordSheet.parse('{tempo: 120}\n{time: 3/4}\n{capo: 5}\n[G]la', id: 'x');
      expect((ok.tempo, ok.beatsPerBar, ok.capo), (120, 3, 5));
    });

    test('YouTube links are recognised and normalized', () {
      const id = 'dQw4w9WgXcQ';
      for (final link in [
        'https://www.youtube.com/watch?v=$id',
        'https://youtube.com/watch?v=$id&t=42s',
        'youtu.be/$id',
        'https://youtu.be/$id?si=abc',
        'https://m.youtube.com/watch?v=$id',
        'https://music.youtube.com/watch?v=$id',
        'https://www.youtube.com/shorts/$id',
      ]) {
        expect(youtubeUrl(link), 'https://www.youtube.com/watch?v=$id', reason: link);
      }
      for (final bad in ['', 'hello', 'https://vimeo.com/123', 'https://youtube.com/watch?v=short']) {
        expect(youtubeUrl(bad), isNull, reason: bad);
      }
      final sheet = ChordSheet.parse('{title: X}\n{youtube: youtu.be/$id}\n[G]Hi', id: 'y');
      expect(sheet.link, 'https://www.youtube.com/watch?v=$id');
      expect(ChordSheet.parse(sheet.toChordPro(), id: 'y').link, sheet.link);
    });

    /// [prog] strummed four times a chord, [seconds] per chord, through the mic analyzer.
    ChordFinder listenTo(List<String> prog, {double seconds = 2}) {
      final synth = GuitarSynth();
      final out = Float32List(((prog.length * seconds + 1) * synth.sampleRate).round());
      for (var i = 0; i < prog.length; i++) {
        final notes = library.byId(prog[i]).midiNotes;
        for (var k = 0; k < 4; k++) {
          final at = ((i * seconds + k * seconds / 4) * synth.sampleRate).round();
          // Each strum rings until the next one strikes the strings again (or the chord change
          // stops them), as on a guitar; not on under every chord after it.
          synth.addStrum(out, at, notes,
              seed: i * 10 + k, gain: 0.5, lengths: [for (final _ in notes) (seconds / 4 * synth.sampleRate).round()]);
        }
      }
      GuitarSynth.normalize(out);
      final finder = ChordFinder();
      for (final f in AudioAnalyzer().add(out)) {
        finder.add(f);
      }
      return finder;
    }

    test('the chord finder writes down what it hears', () {
      for (final prog in [
        ['G', 'C', 'D', 'Em'],
        ['C', 'G', 'Am', 'F'],
        ['Dm', 'Bb', 'C', 'Am'],
      ]) {
        final finder = listenTo(prog);
        expect([for (final c in finder.chords) c.name], prog);
        expect(finder.chords.first.start, lessThan(0.6));
        final sheet = ChordSheet.parse(finder.toSheetText(), id: 'found');
        expect(sheet.chordNames, prog, reason: 'the chart reads back as a chord sheet');
      }
    });

    /// What the finder writes for [out] (normalized first).
    List<String> found(Float32List out) {
      GuitarSynth.normalize(out, 0.5);
      final finder = ChordFinder();
      for (final f in AudioAnalyzer(gate: 0.006).add(out)) {
        finder.add(f);
      }
      return [for (final c in finder.chords) c.name];
    }

    /// The notes of a library voicing by string (6 = low E), low to high.
    Map<int, int> strings(String id) {
      final frets = library.byId(id).frets;
      return {for (var i = 0; i < 6; i++) if (frets[i] >= 0) 6 - i: midiAt(6 - i, frets[i])};
    }

    test('chords picked one string at a time are written down', () {
      final synth = GuitarSynth();
      for (final prog in [
        ['Am', 'F', 'C', 'G'],
        ['C', 'G', 'Am', 'F'],
      ]) {
        const bar = 2.4, pattern = [0, 3, 2, 1, 2, 3, 2, 1]; // 0: the chord's lowest string
        final out = Float32List(((prog.length * bar + 1) * synth.sampleRate).round());
        final eighth = (bar / 8 * synth.sampleRate).round();
        for (var b = 0; b < prog.length; b++) {
          final notes = strings(prog[b]);
          for (var k = 0; k < 8; k++) {
            final midi = pattern[k] == 0 ? notes[notes.keys.reduce(math.max)]! : notes[pattern[k]]!;
            // Each note stops as the next is picked: only ever one string sounding.
            synth.addNote(out, ((b * bar) * synth.sampleRate).round() + k * eighth, midi,
                seed: b * 8 + k, lengthSamples: eighth);
          }
        }
        expect(found(out), prog);
      }
    });

    test('a melody on single strings, passing notes and all, does not change the chord', () {
      final synth = GuitarSynth();
      const bar = 2.4;
      final out = Float32List(((2 * bar + 1) * synth.sampleRate).round());
      final eighth = (bar / 8 * synth.sampleRate).round();
      final g = strings('G');
      // G4 A4 B4 C5 D5 B4 A4: A and C aren't in G.
      const melody = [67, 69, 71, 72, 74, 71, 69];
      for (var b = 0; b < 2; b++) {
        final start = (b * bar * synth.sampleRate).round();
        synth.addStrum(out, start, g.values.toList(), seed: b, gain: 0.6);
        for (var k = 0; k < 4; k++) {
          synth.addNote(out, start + k * 2 * eighth, 43, gain: 0.8, seed: 50 + k, lengthSamples: 2 * eighth); // bass G
        }
        for (var k = 0; k < melody.length; k++) {
          synth.addNote(out, start + (k + 1) * eighth, melody[k], seed: 9 * b + k, lengthSamples: eighth);
        }
      }
      expect(found(out), ['G']);
    });

    test('two-note power chords take major or minor from the key', () {
      final synth = GuitarSynth();
      const prog = ['A5', 'F5', 'C5', 'G5'];
      const bar = 2.4;
      final out = Float32List(((2 * prog.length * bar + 1) * synth.sampleRate).round());
      final beat = (bar / 4 * synth.sampleRate).round();
      for (var b = 0; b < 2 * prog.length; b++) {
        final notes = library.byId(prog[b % prog.length]).midiNotes.take(2).toList(); // root and fifth
        for (var k = 0; k < 4; k++) {
          synth.addStrum(out, (b * bar * synth.sampleRate).round() + k * beat, notes,
              seed: b * 4 + k, gain: 0.6, lengths: [beat, beat]);
        }
      }
      // A and E alone could be A or Am; in a song of F, C and G, it's Am.
      expect(found(out), ['Am', 'F', 'C', 'G', 'Am', 'F', 'C', 'G']);
    });

    test('a chord too short to trust is skipped', () {
      final finder = listenTo(['G', 'C', 'G'], seconds: 0.5);
      expect([for (final c in finder.chords) c.name], ['G']);
    });

    test('quick changes are kept, the first chord included', () {
      expect([for (final c in listenTo(['G', 'C', 'G'], seconds: 0.7).chords) c.name], ['G', 'C', 'G']);
      expect([for (final c in listenTo(['G', 'C', 'D', 'Em'], seconds: 0.5).chords) c.name], ['G', 'C', 'D', 'Em']);
    });

    test('listening carries on after a pause restarts the mic clock', () {
      final finder = ChordFinder();
      for (var i = 0; i < 20; i++) {
        finder.add(AnalysisFrame(time: i * 0.05, rms: 0));
      }
      final before = finder.elapsed;
      for (var i = 0; i < 20; i++) {
        finder.add(AnalysisFrame(time: i * 0.05, rms: 0));
      }
      expect(finder.elapsed, greaterThan(before));
    });

    test('with a video clock, chords are placed at the video time', () {
      final finder = ChordFinder();
      // Silence at the start of the video, then frames placed at 30s onward.
      for (var i = 0; i < 40; i++) {
        finder.add(AnalysisFrame(time: i * 0.05, rms: 0), at: 30 + i * 0.05);
      }
      expect(finder.elapsed, closeTo(31.95, 1e-9));
      // Wound back: the clock follows the video rather than carrying on.
      finder.add(const AnalysisFrame(time: 2.0, rms: 0), at: 10);
      expect(finder.elapsed, 10);
    });

    test('PCM bytes split mid-sample decode the same as whole', () {
      final bytes = Uint8List.fromList([0x00, 0x40, 0xFF, 0x7F, 0x00, 0x80, 0x01, 0x00]);
      final whole = Pcm16Decoder().decode(bytes);
      expect(whole, [0.5, 32767 / 32768, -1.0, 1 / 32768]);
      final split = Pcm16Decoder();
      final parts = [...split.decode(bytes.sublist(0, 3)), ...split.decode(bytes.sublist(3))];
      expect(parts, whole);
    });

    test('a sheet becomes a practice chart in the shapes shown', () {
      final sheets = bundledSheets();
      final grace = sheets.firstWhere((s) => s.id == 'pd:amazing_grace');
      final song = sheetSong(grace, shape: (n) => transposeName(n, 2), resolver: resolver);
      expect(song.lines.first.bars, ['A', 'A7', 'D', 'A']);
      expect(song.beatsPerBar, 3);
      expect(song.pattern, 'D-DUDU');
      expect(song.bpm, 80);
      expect(song.lines.first.lyrics, 'Amazing grace, how sweet the sound');
      for (final id in song.bars) {
        expect(sheetChord(id, resolver).midiNotes, isNotEmpty);
      }
      final tabOnly = sheets.firstWhere((s) => s.id == 'pd:fur_elise');
      expect(sheetSong(tabOnly, shape: (n) => n, resolver: resolver).lines, isEmpty);
    });
  });

  group('splash', () {
    for (final sound in [true, false]) {
      testWidgets('strums the open strings, then opens the app (sound ${sound ? 'on' : 'off'})', (tester) async {
        SharedPreferences.setMockInitialValues({});
        final progress = ProgressStore(await SharedPreferences.getInstance())..openingSound = sound;
        final player = _OpeningPlayer();
        final services = AppServices(
          library: library,
          curriculum: Curriculum.fromJson(File('assets/data/curriculum.json').readAsStringSync()),
          player: player,
          sheets: const [],
        );
        await tester.pumpWidget(GuitaroApp(services: services, progress: progress, mic: FakeMic(), splash: true));
        expect(find.text('Guitaro'), findsOneWidget);
        expect(player.opens, sound ? 1 : 0);
        expect(find.byType(NavigationBar), findsNothing);

        await tester.pump(SplashScreen.duration);
        await tester.pumpAndSettle();
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(find.byType(SplashScreen), findsNothing);
        expect(player.opens, sound ? 1 : 0);
      });
    }
  });

  group('screens', () {
    Future<SongbookStore> pump(WidgetTester tester, {FakeMic? mic}) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final songbook = SongbookStore(prefs);
      final services = AppServices(
        library: library,
        curriculum: Curriculum.fromJson(File('assets/data/curriculum.json').readAsStringSync()),
        player: SoundPlayer(),
        sheets: bundledSheets(),
      );
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        GuitaroApp(services: services, progress: ProgressStore(prefs), mic: mic ?? FakeMic(), songbook: songbook),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Songs').last);
      await tester.pumpAndSettle();
      return songbook;
    }

    testWidgets('search, open a sheet, transpose and favorite', (tester) async {
      final songbook = await pump(tester);
      await tester.enterText(find.byType(TextField), 'newton');
      await tester.pumpAndSettle();
      final sheetTile = find.descendant(of: find.byType(SheetTile), matching: find.text('Amazing Grace'));
      expect(sheetTile, findsOneWidget);
      expect(find.text('Greensleeves'), findsNothing);

      await tester.tap(sheetTile);
      await tester.pumpAndSettle();
      expect(find.text('Key G'), findsOneWidget);
      expect(find.text('Verse 1'), findsOneWidget);

      await tester.tap(find.text('Tools'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Transpose up'));
      await tester.tap(find.byTooltip('Transpose up'));
      await tester.pumpAndSettle();
      expect(songbook.prefsFor('pd:amazing_grace').transpose, 2);
      await tester.tapAt(const Offset(20, 100));
      await tester.pumpAndSettle();
      expect(find.text('Key A'), findsOneWidget);
      expect(find.text('Transposed +2'), findsOneWidget);

      await tester.tap(find.byTooltip('Add to favorites'));
      await tester.pumpAndSettle();
      expect(songbook.isFavorite('pd:amazing_grace'), isTrue);
      expect(songbook.recent.first, 'pd:amazing_grace');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a chords-only line shows each chord once', (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'shuffle');
      await tester.pumpAndSettle();
      await tester.tap(find.text('12-Bar Blues Shuffle in E'));
      await tester.pumpAndSettle();
      final bars = find.descendant(of: find.byType(SheetBody), matching: find.text('B'));
      expect(bars, findsOneWidget, reason: 'B is written once, in bar 9');
    });

    testWidgets('a tab opens in the player', (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'ode to joy');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ode to Joy'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Play tab'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Play tab'));
      await tester.pumpAndSettle();
      expect(find.byType(TabPlayerScreen), findsOneWidget);
      expect(find.text('Loop'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('write a song in My songs', (tester) async {
      final songbook = await pump(tester);
      await tester.tap(find.text('My songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New song'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Porch Song');
      await tester.enterText(find.byType(TextField).last, 'G        D\nSitting on the porch');
      await tester.tap(find.byTooltip('Preview'));
      await tester.pumpAndSettle();
      expect(find.text('Porch Song'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(songbook.userSongs.single.title, 'Porch Song');
      expect(find.text('Porch Song'), findsOneWidget, reason: 'listed under My songs');
      expect(tester.takeException(), isNull);
    });

    testWidgets('play along with a sheet, the song strumming with you', (tester) async {
      final mic = FakeMic();
      await pump(tester, mic: mic);
      await tester.enterText(find.byType(TextField), 'amazing');
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(SheetTile), matching: find.text('Amazing Grace')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play along'));
      await tester.pumpAndSettle();
      expect(find.byType(SongView), findsOneWidget);
      expect(mic.users, 1, reason: 'wait mode listens');
      await tester.tap(find.descendant(of: find.byType(SegmentedButton<SongMode>), matching: find.text('Play along')));
      await tester.pumpAndSettle();
      final backing = tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Play the song with me'));
      expect(backing.value, isTrue);
      expect(find.text('Start'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(mic.users, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a song keeps its YouTube link', (tester) async {
      final songbook = await pump(tester);
      await tester.tap(find.text('My songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New song'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Linked');
      final link = find.widgetWithText(TextField, 'YouTube link (optional)');
      await tester.enterText(link, 'not a link');
      await tester.enterText(find.byType(TextField).last, 'G  C\nHello');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text("That doesn't look like a YouTube link."), findsOneWidget);
      expect(songbook.userSongs, isEmpty);

      await tester.enterText(link, 'youtu.be/dQw4w9WgXcQ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(songbook.userSongs.single.link, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      await tester.tap(find.text('Linked'));
      await tester.pumpAndSettle();
      expect(find.text('Watch on YouTube'), findsOneWidget);
      expect(find.text('Play along'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the chord finder holds the mic only while listening', (tester) async {
      final mic = FakeMic();
      await pump(tester, mic: mic);
      await tester.tap(find.text('My songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find chords by listening'));
      await tester.pumpAndSettle();
      expect(mic.users, 0);
      await tester.tap(find.text('Start listening'));
      await tester.pumpAndSettle();
      expect(mic.users, 1);
      await tester.tap(find.text('Pause'));
      await tester.pumpAndSettle();
      expect(mic.users, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tabs still switch after coming back from a song', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Amazing Grace').first);
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('My songs'));
      await tester.pumpAndSettle();
      expect(find.text('Find chords by listening'), findsOneWidget);
      expect(find.byType(SongView), findsNothing);
    });
  });
}

class _OpeningPlayer extends SoundPlayer {
  int opens = 0;

  @override
  Future<Duration> playOpenStrings() async {
    opens++;
    return Duration.zero;
  }
}
