import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chord_sheet.dart';

/// How a learner last viewed a sheet: remembered per song, the way tab sites keep your
/// transposition.
class SheetPrefs {
  const SheetPrefs({this.transpose = 0, this.capo, this.simplify = false, this.fontScale = 1.0, this.scrollSpeed = 3});

  /// Semitones the song is moved from how it's written.
  final int transpose;

  /// The learner's capo, or null for the one the sheet is written for.
  final int? capo;
  final bool simplify;
  final double fontScale;

  /// Autoscroll speed, 1..10.
  final int scrollSpeed;

  SheetPrefs copyWith({int? transpose, int? Function()? capo, bool? simplify, double? fontScale, int? scrollSpeed}) =>
      SheetPrefs(
        transpose: transpose ?? this.transpose,
        capo: capo == null ? this.capo : capo(),
        simplify: simplify ?? this.simplify,
        fontScale: fontScale ?? this.fontScale,
        scrollSpeed: scrollSpeed ?? this.scrollSpeed,
      );

  factory SheetPrefs.fromJson(Map<String, dynamic> j) => SheetPrefs(
        transpose: (j['transpose'] as num?)?.toInt() ?? 0,
        capo: (j['capo'] as num?)?.toInt(),
        simplify: j['simplify'] as bool? ?? false,
        fontScale: (j['fontScale'] as num?)?.toDouble() ?? 1.0,
        scrollSpeed: (j['scrollSpeed'] as num?)?.toInt() ?? 3,
      );

  Map<String, dynamic> toJson() => {
        'transpose': transpose,
        if (capo != null) 'capo': capo,
        'simplify': simplify,
        'fontScale': fontScale,
        'scrollSpeed': scrollSpeed,
      };
}

class Setlist {
  const Setlist({required this.id, required this.name, this.sheetIds = const []});

  final String id, name;
  final List<String> sheetIds;

  Setlist copyWith({String? name, List<String>? sheetIds}) =>
      Setlist(id: id, name: name ?? this.name, sheetIds: sheetIds ?? this.sheetIds);

  factory Setlist.fromJson(Map<String, dynamic> j) =>
      Setlist(id: j['id'] as String, name: j['name'] as String, sheetIds: List<String>.from(j['sheets'] as List));

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'sheets': sheetIds};
}

/// A song the learner typed or pasted. The body is kept exactly as written; title, artist,
/// key and capo come from the form and override anything in the body.
class UserSong {
  const UserSong({
    required this.id,
    required this.title,
    this.artist = '',
    this.key = '',
    this.capo = 0,
    this.tempo,
    this.link,
    required this.body,
  });

  final String id, title, artist, key, body;
  final int capo;
  final int? tempo;

  /// A YouTube link for the song, already normalized by [youtubeUrl].
  final String? link;

  ChordSheet toSheet() {
    final parsed = ChordSheet.parse(body, id: id);
    return parsed.copyWith(
      title: title.trim().isNotEmpty ? title.trim() : null,
      artist: artist.trim().isNotEmpty ? artist.trim() : null,
      key: key.trim().isNotEmpty ? key.trim() : null,
      capo: capo > 0 ? capo : null,
      tempo: tempo,
      link: link,
    );
  }

  factory UserSong.fromJson(Map<String, dynamic> j) => UserSong(
        id: j['id'] as String,
        title: j['title'] as String,
        artist: j['artist'] as String? ?? '',
        key: j['key'] as String? ?? '',
        capo: (j['capo'] as num?)?.toInt() ?? 0,
        tempo: (j['tempo'] as num?)?.toInt(),
        link: j['link'] as String?,
        body: j['body'] as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'key': key,
        'capo': capo,
        if (tempo != null) 'tempo': tempo,
        if (link != null) 'link': link,
        'body': body,
      };
}

/// Favorites, recently viewed, setlists, the learner's own songs and per-song view settings,
/// persisted as one JSON blob. Without [prefs] it keeps everything in memory.
class SongbookStore extends ChangeNotifier {
  SongbookStore([this._prefs]) {
    final raw = _prefs?.getString(_key);
    if (raw == null) return;
    // Read entry by entry: a damaged one is skipped, not allowed to stop the app from starting
    // or to take the learner's other songs with it.
    var damaged = false;
    T? read<T>(T Function() decode) {
      try {
        return decode();
      } catch (e) {
        debugPrint('SongbookStore: skipped a damaged entry ($e)');
        damaged = true;
        return null;
      }
    }

    final j = read(() => jsonDecode(raw) as Map<String, dynamic>) ?? const <String, dynamic>{};
    _favorites.addAll(read(() => List<String>.from(j['favorites'] as List? ?? const [])) ?? const []);
    _recent.addAll(read(() => List<String>.from(j['recent'] as List? ?? const [])) ?? const []);
    for (final s in read(() => j['setlists'] as List? ?? const []) ?? const []) {
      final setlist = read(() => Setlist.fromJson(s as Map<String, dynamic>));
      if (setlist != null) _setlists.add(setlist);
    }
    for (final s in read(() => j['songs'] as List? ?? const []) ?? const []) {
      final song = read(() => UserSong.fromJson(s as Map<String, dynamic>));
      if (song != null) _songs[song.id] = song;
    }
    (read(() => j['prefs'] as Map? ?? const {}) ?? const {}).forEach((k, v) {
      final prefs = read(() => SheetPrefs.fromJson(v as Map<String, dynamic>));
      if (prefs != null) _prefsBySheet['$k'] = prefs;
    });
    // The next save writes only what was read; keep the original.
    if (damaged) _prefs?.setString('$_key.damaged', raw);
  }

  static const _key = 'songbook.v1';
  static const maxRecent = 20;
  final SharedPreferences? _prefs;
  final List<String> _favorites = [];
  final List<String> _recent = [];
  final List<Setlist> _setlists = [];
  final Map<String, UserSong> _songs = {};
  final Map<String, SheetPrefs> _prefsBySheet = {};

  List<String> get favorites => List.unmodifiable(_favorites);
  List<String> get recent => List.unmodifiable(_recent);
  List<Setlist> get setlists => List.unmodifiable(_setlists);
  List<UserSong> get userSongs =>
      _songs.values.toList()..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  UserSong? userSong(String id) => _songs[id];

  bool isFavorite(String sheetId) => _favorites.contains(sheetId);

  SheetPrefs prefsFor(String sheetId) => _prefsBySheet[sheetId] ?? const SheetPrefs();

  Setlist? setlist(String id) => _setlists.where((s) => s.id == id).firstOrNull;

  void toggleFavorite(String sheetId) =>
      _update(() => _favorites.contains(sheetId) ? _favorites.remove(sheetId) : _favorites.insert(0, sheetId));

  void markViewed(String sheetId) => _update(() {
        _recent
          ..remove(sheetId)
          ..insert(0, sheetId);
        if (_recent.length > maxRecent) _recent.removeRange(maxRecent, _recent.length);
      });

  void setPrefs(String sheetId, SheetPrefs prefs) => _update(() => _prefsBySheet[sheetId] = prefs);

  Setlist createSetlist(String name) {
    final s = Setlist(
      id: 'set:${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'Setlist' : name.trim(),
    );
    _update(() => _setlists.add(s));
    return s;
  }

  void renameSetlist(String id, String name) => _replaceSetlist(id, (s) => s.copyWith(name: name));

  void deleteSetlist(String id) => _update(() => _setlists.removeWhere((s) => s.id == id));

  void addToSetlist(String setlistId, String sheetId) => _replaceSetlist(
        setlistId,
        (s) => s.sheetIds.contains(sheetId) ? s : s.copyWith(sheetIds: [...s.sheetIds, sheetId]),
      );

  void removeFromSetlist(String setlistId, String sheetId) =>
      _replaceSetlist(setlistId, (s) => s.copyWith(sheetIds: [...s.sheetIds]..remove(sheetId)));

  /// Moves the song at [from] so it ends up at index [to].
  void reorderSetlist(String setlistId, int from, int to) => _replaceSetlist(setlistId, (s) {
        final ids = [...s.sheetIds];
        final id = ids.removeAt(from);
        ids.insert(to.clamp(0, ids.length), id);
        return s.copyWith(sheetIds: ids);
      });

  /// Puts [ordered], some of a setlist's songs in a new order, into the places they held.
  /// The rest stay put: a screen that can't show a song (one that no longer opens) reorders the
  /// songs it shows without its indexes landing on the hidden ones.
  void arrangeSetlist(String setlistId, List<String> ordered) => _replaceSetlist(setlistId, (s) {
        final moving = ordered.toSet();
        final next = ordered.iterator;
        return s.copyWith(sheetIds: [
          for (final id in s.sheetIds) moving.contains(id) && next.moveNext() ? next.current : id,
        ]);
      });

  /// Saves [song]; a song without an id gets a new one. Returns the saved song.
  UserSong saveUserSong(UserSong song) {
    final saved = song.id.isNotEmpty
        ? song
        : UserSong(
            id: 'my:${DateTime.now().microsecondsSinceEpoch}',
            title: song.title,
            artist: song.artist,
            key: song.key,
            capo: song.capo,
            tempo: song.tempo,
            link: song.link,
            body: song.body,
          );
    _update(() => _songs[saved.id] = saved);
    return saved;
  }

  /// Deletes a user song and every reference to it.
  void deleteUserSong(String id) => _update(() {
        _songs.remove(id);
        _favorites.remove(id);
        _recent.remove(id);
        _prefsBySheet.remove(id);
        for (var i = 0; i < _setlists.length; i++) {
          _setlists[i] = _setlists[i].copyWith(sheetIds: [..._setlists[i].sheetIds]..remove(id));
        }
      });

  void _replaceSetlist(String id, Setlist Function(Setlist) change) => _update(() {
        final i = _setlists.indexWhere((s) => s.id == id);
        if (i >= 0) _setlists[i] = change(_setlists[i]);
      });

  void _update(void Function() change) {
    change();
    _prefs?.setString(
      _key,
      jsonEncode({
        'favorites': _favorites,
        'recent': _recent,
        'setlists': [for (final s in _setlists) s.toJson()],
        'songs': [for (final s in _songs.values) s.toJson()],
        'prefs': {for (final e in _prefsBySheet.entries) e.key: e.value.toJson()},
      }),
    );
    notifyListeners();
  }
}
