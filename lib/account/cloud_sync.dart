import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_service.dart';

/// A store that cloud sync carries: where it's saved, and how to read it in again once the
/// account's copy has replaced it.
typedef SyncedStore = ({String key, Listenable store, void Function() reload});

/// Keeps the learner's progress, practice and songbook in their account: backed up, and the same
/// on every phone they sign in on. Local-first: the app always works from what's on the phone,
/// and the account's copy follows a few seconds after each change. When the account's copy is
/// newer (they played on another phone), it comes down and replaces this phone's.
class CloudSync extends ChangeNotifier {
  CloudSync({
    required this.accounts,
    required this.prefs,
    required this.stores,
    required this.localIsEmpty,
    this.delay = const Duration(seconds: 5),
  });

  final AccountService accounts;
  final SharedPreferences prefs;
  final List<SyncedStore> stores;

  /// Nothing on this phone worth keeping over the account's copy.
  final bool Function() localIsEmpty;

  /// How long after a change the account's copy follows: changes come in bursts.
  final Duration delay;

  static const _syncedAtKey = 'sync.at', _changedKey = 'sync.changed', _uidKey = 'sync.uid';

  Timer? _timer;
  bool _applying = false, _busy = false, _failed = false;

  /// When this phone and the account's copy last matched.
  DateTime? get syncedAt => switch (prefs.getInt(_syncedAtKey)) {
        null => null,
        final ms => DateTime.fromMillisecondsSinceEpoch(ms),
      };

  /// Backing up or bringing changes down right now.
  bool get busy => _busy;

  /// The last try didn't get through (offline): it tries again with the next change.
  bool get failed => _failed;

  /// Changed on this phone since it last matched the account's copy.
  bool get _changed => prefs.getBool(_changedKey) ?? false;

  /// Starts following changes to the stores.
  void start() {
    for (final s in stores) {
      s.store.addListener(_onChange);
    }
  }

  void _onChange() {
    if (_applying) return;
    prefs.setBool(_changedKey, true);
    if (accounts.account == null) return;
    _timer?.cancel();
    _timer = Timer(delay, () => _guard(_upload));
  }

  /// Right after signing in: brings this phone and the account together. A first phone fills
  /// the account; a fresh phone takes the account's copy; when both have progress,
  /// [useAccountCopy] asks the learner which to keep.
  Future<void> connect({required Future<bool> Function() useAccountCopy}) => _guard(() async {
        final uid = accounts.account?.id;
        if (uid == null) return;
        final cloud = await accounts.fetch();
        final sameAccount = prefs.getString(_uidKey) == uid;
        await prefs.setString(_uidKey, uid);
        if (cloud == null) return _upload();
        if (localIsEmpty() || (sameAccount && !_changed)) return _apply(cloud);
        if (await useAccountCopy()) return _apply(cloud);
        await _upload();
      });

  /// The account is gone: this phone no longer matches anything.
  Future<void> forget() async {
    _timer?.cancel();
    await prefs.remove(_uidKey);
    await prefs.remove(_syncedAtKey);
    notifyListeners();
  }

  /// At start, already signed in: changes made here go up; newer ones from another phone come
  /// down.
  Future<void> resume() => _guard(() async {
        if (accounts.account == null) return;
        final cloud = await accounts.fetch();
        if (cloud == null || _changed) return _upload();
        final at = syncedAt;
        if (at == null || cloud.savedAt.isAfter(at)) await _apply(cloud);
      });

  Future<void> _upload() async {
    _timer?.cancel();
    // Signed out since the change: it stays marked as changed, to go up at the next sign-in.
    if (accounts.account == null) return;
    final savedAt = await accounts.store({for (final s in stores) s.key: prefs.getString(s.key) ?? ''});
    await prefs.setInt(_syncedAtKey, savedAt.millisecondsSinceEpoch);
    await prefs.setBool(_changedKey, false);
  }

  Future<void> _apply(CloudCopy cloud) async {
    _applying = true;
    try {
      for (final s in stores) {
        final saved = cloud.data[s.key];
        // An older app's copy may not have this store: keep the phone's.
        if (saved == null || saved.isEmpty) continue;
        await prefs.setString(s.key, saved);
        s.reload();
      }
    } finally {
      _applying = false;
    }
    await prefs.setInt(_syncedAtKey, cloud.savedAt.millisecondsSinceEpoch);
    await prefs.setBool(_changedKey, false);
  }

  /// Runs [work], reporting progress, and treating a failure (offline, mostly) as "try later".
  Future<void> _guard(Future<void> Function() work) async {
    _busy = true;
    notifyListeners();
    try {
      await work();
      _failed = false;
    } catch (e) {
      debugPrint('CloudSync: $e');
      _failed = true;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final s in stores) {
      s.store.removeListener(_onChange);
    }
    super.dispose();
  }
}
