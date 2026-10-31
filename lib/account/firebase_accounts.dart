import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'account_service.dart';

/// Accounts through Firebase: Google (and Apple) sign-in with Firebase Auth, which shows the
/// provider's own sign-in page in a secure browser sheet, and the learner's
/// copy in Cloud Firestore at `users/{uid}`, which only they can read or write (see
/// firestore.rules). Both are on Firebase's free plan.
class FirebaseAccounts extends AccountService {
  FirebaseAccounts() {
    _changes = FirebaseAuth.instance.authStateChanges().listen((_) => notifyListeners());
  }

  /// Sign in with Apple needs the Apple developer setup (see README), so it's switched on per
  /// build: `--dart-define=APPLE_SIGN_IN=true`.
  static const _appleSwitchedOn = bool.fromEnvironment('APPLE_SIGN_IN');

  late final StreamSubscription<User?> _changes;

  FirebaseAuth get _auth => FirebaseAuth.instance;
  DocumentReference<Map<String, dynamic>> _doc(String uid) => FirebaseFirestore.instance.collection('users').doc(uid);

  @override
  bool get available => true;

  @override
  bool get appleAvailable =>
      _appleSwitchedOn && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Account? get account => switch (_auth.currentUser) {
        null => null,
        final u => Account(
            id: u.uid,
            name: u.displayName ?? '',
            email: u.email ?? '',
            photoUrl: u.photoURL,
            provider: u.providerData.firstOrNull?.providerId ?? '',
          ),
      };

  GoogleAuthProvider get _google => GoogleAuthProvider()..setCustomParameters({'prompt': 'select_account'});

  /// Signs in through [provider]; null when the learner backs out.
  Future<Account?> _signIn(AuthProvider provider) async {
    try {
      await _auth.signInWithProvider(provider);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'canceled' || e.code == 'web-context-canceled' || e.code == 'user-cancelled') return null;
      rethrow;
    }
    return account;
  }

  @override
  Future<Account?> signInWithGoogle() => _signIn(_google);

  AppleAuthProvider get _apple => AppleAuthProvider()
    ..addScope('email')
    ..addScope('name');

  @override
  Future<Account?> signInWithApple() => _signIn(_apple);

  @override
  Future<void> signOut() => _auth.signOut();

  @override
  Future<void> deleteAccount() async {
    final user = _auth.currentUser;
    if (user == null) return;
    await _doc(user.uid).delete();
    try {
      await user.delete();
    } on FirebaseAuthException catch (e) {
      // Deleting needs a recent sign-in: sign in again, then delete.
      if (e.code != 'requires-recent-login') rethrow;
      await user.reauthenticateWithProvider(user.providerData.any((p) => p.providerId == 'apple.com') ? _apple : _google);
      await user.delete();
    }
    await signOut();
  }

  @override
  Future<CloudCopy?> fetch() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    final snap = await _doc(user.uid).get();
    final j = snap.data();
    if (j == null) return null;
    return (
      data: {for (final MapEntry(:key, :value) in (j['stores'] as Map? ?? const {}).entries) key as String: value as String},
      savedAt: (j['savedAt'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// Saved with the phone's time, which the next sync compares with its own: the two clocks
  /// agree closely enough to tell which copy is newer.
  @override
  Future<DateTime> store(Map<String, String> data) async {
    final savedAt = DateTime.now();
    final user = _auth.currentUser;
    if (user != null) await _doc(user.uid).set({'stores': data, 'savedAt': Timestamp.fromDate(savedAt)});
    return savedAt;
  }

  @override
  void dispose() {
    _changes.cancel();
    super.dispose();
  }
}
