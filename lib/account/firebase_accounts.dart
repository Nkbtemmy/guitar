import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'account_service.dart';

/// Accounts through Firebase: Google (and Apple) sign-in with Firebase Auth, and the learner's
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
  Future<void>? _google;

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

  /// The Google sign-in plugin needs setting up once before use.
  Future<void> _googleReady() => _google ??= GoogleSignIn.instance.initialize();

  Future<AuthCredential?> _googleCredential() async {
    await _googleReady();
    try {
      final user = await GoogleSignIn.instance.authenticate();
      return GoogleAuthProvider.credential(idToken: user.authentication.idToken);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  @override
  Future<Account?> signInWithGoogle() async {
    final credential = await _googleCredential();
    if (credential == null) return null;
    await _auth.signInWithCredential(credential);
    return account;
  }

  AppleAuthProvider get _apple => AppleAuthProvider()
    ..addScope('email')
    ..addScope('name');

  @override
  Future<Account?> signInWithApple() async {
    try {
      await _auth.signInWithProvider(_apple);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'canceled' || e.code == 'web-context-canceled') return null;
      rethrow;
    }
    return account;
  }

  @override
  Future<void> signOut() async {
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Signed in with Apple, or Google never set up: nothing to sign out of there.
    }
    await _auth.signOut();
  }

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
      if (user.providerData.any((p) => p.providerId == 'apple.com')) {
        await user.reauthenticateWithProvider(_apple);
      } else {
        final credential = await _googleCredential();
        if (credential == null) return;
        await user.reauthenticateWithCredential(credential);
      }
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

  @override
  Future<void> store(Map<String, String> data) async {
    final user = _auth.currentUser;
    if (user == null) return;
    await _doc(user.uid).set({'stores': data, 'savedAt': FieldValue.serverTimestamp()});
  }

  @override
  void dispose() {
    _changes.cancel();
    super.dispose();
  }
}
