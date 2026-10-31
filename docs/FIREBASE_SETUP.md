# Setting up Firebase (free plan)

Guitaro uses Firebase for:
- sign-in (Google, and Apple later);
- backing up learners' progress (Cloud Firestore);
- anonymous usage stats and crash reports.

Everything here fits Firebase's free **Spark** plan. No card is needed.

Until these steps are done the app works as before. Sign-in simply isn't offered, and everything
stays on the phone.

## 1. Create the project and connect the app

```sh
npm install -g firebase-tools
firebase login
dart pub global activate flutterfire_cli
flutterfire configure --platforms=android,ios \
    --android-package-name=com.thunderzeye.guitaro --ios-bundle-id=com.thunderzeye.guitaro
```

1. Pick "create a new project".
2. The command writes `lib/firebase_options.dart`, `android/app/google-services.json` and
   `ios/Runner/GoogleService-Info.plist`.
3. Then tell Claude (or change `startFirebase()` in `lib/main.dart` to
   `startFirebase(options: DefaultFirebaseOptions.currentPlatform)`).

## 2. Turn on Google sign-in

In the Firebase console: **Build › Authentication › Get started › Sign-in method › Google ›
Enable**. Pick a support email, then **Save**.

## 3. Register the app's signing keys (Android)

Google sign-in only works for builds whose signing key Firebase knows. In **Project settings ›
Your apps › Android app › Add fingerprint**, add the SHA-1 *and* SHA-256 of:

- **The debug key** (for `flutter run`):
  `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android`
- **Your upload key** (see README, Release builds):
  `keytool -list -v -keystore ~/guitaro-upload.jks -alias upload`
- **Google Play's app signing key**, once the app is in Play Console. It's under **Test and
  release › App integrity › App signing**.

Then download `google-services.json` again into `android/app/` (or run `flutterfire configure`
again).

## 4. iPhone: let Google sign-in come back to the app

Google's sign-in page opens in a browser sheet, and comes back to the app through a URL scheme.
Open `ios/Runner/GoogleService-Info.plist`, copy its `REVERSED_CLIENT_ID`, and add it as a URL
scheme: in Xcode, **Runner target › Info › URL Types › +**, paste it into **URL Schemes**.

## 5. Create the database

1. **Build › Firestore Database › Create database**.
2. Choose **production mode** and the location nearest your learners (e.g. `eur3`), which can't
   be changed later.
3. Then **Rules**: paste in [`firestore.rules`](../firestore.rules) and **Publish**.

The free plan allows 50,000 reads and 20,000 writes a day, and 1 GB stored. A learner's copy is
a few kilobytes and is written a few times a day, so that's thousands of daily learners.
Recordings are never uploaded.

## 6. Sign in with Apple (when you join the Apple Developer Program)

The App Store requires it whenever Google sign-in is offered.

1. In Xcode, open Runner › **Signing & Capabilities** › **+ Capability** › **Sign in with Apple**.
2. In Firebase, go to **Authentication › Sign-in method › Apple › Enable**.
3. Build with `--dart-define=APPLE_SIGN_IN=true`, for example
   `flutter build ipa --dart-define=APPLE_SIGN_IN=true`.

## 7. Store forms

**Play Console › Data safety**: add the sign-in data on top of what the README already lists for
usage stats:

- **Personal info: Name and Email address.** Collected for account management, optional, and
  deletable.
- **App activity: Other user-generated content** (progress, practice, songs), for app
  functionality.
- **Account deletion**: in the app under Me › Delete account. Play also wants a web link where
  people can ask for deletion without the app, for example a GitHub issue form or an email
  address. Give it in the form.

**App Store Connect › App Privacy**: Contact Info (name, email) and User Content, linked to the
user, for App Functionality, not used for tracking.

## Later: your own backend

All account and sync code goes through `AccountService` (`lib/account/account_service.dart`).
A backend of your own means writing one class that implements it. The screens and the sync logic
(`lib/account/cloud_sync.dart`) stay as they are.
