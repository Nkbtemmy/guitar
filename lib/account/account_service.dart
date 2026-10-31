import 'package:flutter/foundation.dart';

/// Who the learner is signed in as.
@immutable
class Account {
  const Account({required this.id, required this.name, required this.email, this.photoUrl, required this.provider});

  final String id, name, email;
  final String? photoUrl;

  /// How they signed in: "google.com" or "apple.com".
  final String provider;
}

/// The learner's data as kept in their account: each store's saved text by its name, and when
/// it was saved.
typedef CloudCopy = ({Map<String, String> data, DateTime savedAt});

/// Signing in, and the learner's copy of their data in the cloud. An interface, so Firebase can
/// give way to Guitaro's own backend later without the screens changing.
abstract class AccountService extends ChangeNotifier {
  /// Whether this build can sign in at all (accounts are set up for it).
  bool get available;

  /// Sign in with Apple: on Apple's platforms, once it's switched on.
  bool get appleAvailable;

  Account? get account;

  /// Null when the learner backs out.
  Future<Account?> signInWithGoogle();
  Future<Account?> signInWithApple();
  Future<void> signOut();

  /// Deletes the account and everything kept in it, for good.
  Future<void> deleteAccount();

  /// The learner's cloud copy, or null when there's none yet.
  Future<CloudCopy?> fetch();

  /// Replaces the cloud copy with [data]; returns when it was saved.
  Future<DateTime> store(Map<String, String> data);
}

/// A build without accounts: everything stays on the phone.
class NoAccounts extends AccountService {
  @override
  bool get available => false;

  @override
  bool get appleAvailable => false;

  @override
  Account? get account => null;

  @override
  Future<Account?> signInWithGoogle() async => null;

  @override
  Future<Account?> signInWithApple() async => null;

  @override
  Future<void> signOut() async {}

  @override
  Future<void> deleteAccount() async {}

  @override
  Future<CloudCopy?> fetch() async => null;

  @override
  Future<DateTime> store(Map<String, String> data) async => DateTime.now();
}
