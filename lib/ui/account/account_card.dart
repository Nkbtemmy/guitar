import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../account/account_service.dart';
import '../../account/cloud_sync.dart';
import '../theme.dart';

/// Signs in with Google, or Apple when [apple], then brings this phone and the account
/// together (asking which to keep when both have progress). True when the learner is now
/// signed in; a failure says so, and backing out does nothing.
Future<bool> signIn(BuildContext context, {bool apple = false}) async {
  final accounts = context.read<AccountService>();
  final sync = context.read<CloudSync?>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    final account = apple ? await accounts.signInWithApple() : await accounts.signInWithGoogle();
    if (account == null) return false;
    if (sync != null && context.mounted) await sync.connect(useAccountCopy: () => _useAccountCopy(context));
    return true;
  } catch (e) {
    debugPrint('Sign-in failed: $e');
    messenger.showSnackBar(const SnackBar(content: Text("Couldn't sign in. Check your connection and try again.")));
    return false;
  }
}

/// This phone and the account both have progress: which to keep? True for the account's.
Future<bool> _useAccountCopy(BuildContext context) async {
  if (!context.mounted) return true;
  final account = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      title: const Text('Which progress do you want?'),
      content: const Text(
        'This phone and your account both have progress, practice or songs. Keep one: the other is replaced.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text("This phone's")),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text("My account's")),
      ],
    ),
  );
  return account ?? true;
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return d.inDays == 1 ? 'yesterday' : '${d.inDays} days ago';
}

/// Asks first, then deletes the account and its cloud copy. What's on the phone stays.
Future<void> deleteAccount(BuildContext context) async {
  final accounts = context.read<AccountService>();
  final sync = context.read<CloudSync?>();
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Delete your account?'),
      content: const Text(
        'This deletes your Guitaro account and the copy of your progress, practice and songs kept in it, '
        'for good. Everything on this phone stays.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete', style: TextStyle(color: kMiss))),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await accounts.deleteAccount();
    await sync?.forget();
    messenger.showSnackBar(const SnackBar(content: Text('Your account is deleted.')));
  } catch (e) {
    debugPrint('Deleting the account failed: $e');
    messenger.showSnackBar(const SnackBar(content: Text("Couldn't delete the account. Check your connection and try again.")));
  }
}

/// Google and (on iPhone, once switched on) Apple sign-in buttons.
class SignInButtons extends StatelessWidget {
  const SignInButtons({super.key, this.onSignedIn});

  final VoidCallback? onSignedIn;

  @override
  Widget build(BuildContext context) {
    final accounts = context.watch<AccountService>();
    Future<void> go({bool apple = false}) async {
      if (await signIn(context, apple: apple)) onSignedIn?.call();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FilledButton.icon(onPressed: go, icon: const Icon(Icons.account_circle_rounded), label: const Text('Continue with Google')),
      if (accounts.appleAvailable) ...[
        const SizedBox(height: 8),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.black),
          onPressed: () => go(apple: true),
          icon: const Icon(Icons.apple_rounded),
          label: const Text('Continue with Apple'),
        ),
      ],
    ]);
  }
}

/// The account in Me: sign in to back up progress, or who is signed in, with sign out and
/// delete. Nothing at all in a build without accounts.
class AccountCard extends StatelessWidget {
  const AccountCard({super.key});

  @override
  Widget build(BuildContext context) {
    final accounts = context.watch<AccountService>();
    if (!accounts.available) return const SizedBox.shrink();
    final account = accounts.account;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: account == null
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Row(children: [
                  Icon(Icons.cloud_upload_rounded, color: kAccent),
                  SizedBox(width: 10),
                  Expanded(child: Text('Back up your progress', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
                ]),
                const SizedBox(height: 6),
                const Text('Sign in to keep your progress, practice and songs safe, and to carry on from any phone.',
                    style: TextStyle(color: kMuted)),
                const SizedBox(height: 12),
                const SignInButtons(),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: kSurfaceHigh,
                    foregroundImage: account.photoUrl == null ? null : NetworkImage(account.photoUrl!),
                    child: Text((account.name.isNotEmpty ? account.name : account.email).characters.firstOrNull?.toUpperCase() ?? '?',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(account.name.isNotEmpty ? account.name : 'Signed in', style: const TextStyle(fontWeight: FontWeight.w800)),
                      Text(account.email, style: const TextStyle(color: kMuted)),
                    ]),
                  ),
                ]),
                if (context.read<CloudSync?>() case final sync?)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: ListenableBuilder(
                      listenable: sync,
                      builder: (context, _) => Row(children: [
                        Icon(sync.failed ? Icons.cloud_off_rounded : Icons.cloud_done_rounded, size: 18, color: sync.failed ? kMiss : kSuccess),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            switch ((sync.busy, sync.failed, sync.syncedAt)) {
                              (true, _, _) => 'Backing up…',
                              (_, true, _) => "Couldn't reach your account: it will try again",
                              (_, _, null) => 'Not backed up yet',
                              (_, _, final at?) => 'Backed up ${_ago(at)}',
                            },
                            style: const TextStyle(color: kMuted, fontSize: 13),
                          ),
                        ),
                      ]),
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(alignment: WrapAlignment.spaceBetween, children: [
                  TextButton(onPressed: accounts.signOut, child: const Text('Sign out')),
                  TextButton(onPressed: () => deleteAccount(context), child: const Text('Delete account', style: TextStyle(color: kMiss))),
                ]),
              ]),
      ),
    );
  }
}
