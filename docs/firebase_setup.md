# Firebase setup (to do later)

Steps required when you reach the authentication and sync phases of the roadmap. Nothing here has been done: this scaffold contains **no Firebase project ID, API key or credential**, and `lib/firebase/firebase_options.dart` is intentionally empty until the FlutterFire CLI generates it.

Local-only features (wallets, transactions, ...) do not need any of this.

## 0. Windows support - read first

Facts checked on 2026-11-22 (re-check before relying on them; Firebase is changing this area):

| Fact | Source |
|---|---|
| Firebase's Flutter setup page lists **Windows as beta** for `firebase_auth` and `cloud_firestore`. | https://firebase.google.com/docs/flutter/setup |
| The FlutterFire repository's platform table marks Windows for Core, Auth and Firestore with "(*) for development only. Production on Windows is not supported". (Seen in mirrors of the README; confirm in the official repo.) | https://github.com/firebase/flutterfire |
| Windows support for Auth was added in `firebase_auth_platform_interface` 6.19.0 (the `firebase_auth` 4.x line); the original PR noted that some features were missing because the Windows C++ SDK was in public beta. | https://pub.dev/packages/firebase_auth_platform_interface/versions/7.0.8/changelog , https://github.com/firebase/flutterfire/issues/11089 |
| Current Flutter BoM is 5.1.0 (2026-10-22): `firebase_core` 5.1.0, `firebase_auth` 7.0.1, `cloud_firestore` 7.1.0, Windows C++ SDK 14.1.0. | https://firebase.google.com/support/release-notes/flutter.md.txt |
| Users have reported Windows-specific sign-in failures (e.g. `[firebase_auth/unknown-error]` on `signInWithEmailAndPassword`, later resolved by upgrading) - evidence that Windows needs real-device testing. | https://github.com/firebase/flutterfire/issues/12725 |
| Drift works on Windows and Android (`drift_flutter` opens the DB on all native platforms). | https://pub.dev/documentation/drift_flutter/latest/ |

What this means for the project:

- SQLite is the source of truth on both platforms, so the app stays fully usable on Windows even if the cloud connection is limited.
- All FlutterFire code is isolated in `lib/firebase/`; the optional `lib/firebase/rest/` adapters (Identity Toolkit + Firestore REST with the user's ID token) are the replacement path.
- **Do the Windows spike early** (roadmap phase 1) before building sync on top:
  1. Email/password sign-up and sign-in on Windows.
  2. Close and relaunch the app: is the session restored (`currentUser`)? Persistent sessions are a requirement.
  3. Write and read a document under `users/{uid}/...` that your rules allow; confirm a different user is denied.
  4. Go offline, perform operations, come back online, confirm the sync engine behaviour.
  5. Build a Windows release and test it on a clean machine.
  If any step fails, decide between waiting for a newer plugin version and implementing the REST fallback.
- Windows builds of the Firebase plugins use the Firebase **C++ SDK** and need Visual Studio 2022 with the *Desktop development with C++* workload.

## 1. Prerequisites

1. A Google account.
2. Node.js + Firebase CLI: `npm install -g firebase-tools`, then `firebase login`.
3. Dart/Flutter installed; FlutterFire CLI: `dart pub global activate flutterfire_cli` (make sure the pub cache `bin` directory is on `PATH`).

## 2. Create the Firebase project

1. Open the [Firebase console](https://console.firebase.google.com) -> **Add project**.
2. Choose a name; Google Analytics is not needed by this app (leave it off unless you want it).
3. Note the generated **project ID** - it is not stored in this repo; it is passed to the CLI.

## 3. Register the Android app

You normally do not register it by hand: `flutterfire configure` (step 7) registers the Android app using the application ID in `android/app/build.gradle(.kts)` (the `--org` you used when generating the platform folder). Email/password sign-in does not require SHA fingerprints; they only become necessary for Google sign-in or phone auth, which this app does not use.

## 4. Configure Windows

- Prerequisites: Visual Studio 2022 (Desktop development with C++), Windows 10/11 SDK.
- `flutterfire configure --platforms=android,windows` generates Dart options for Windows. As far as I know, Firebase has no separate "Windows app" type and the CLI derives the Windows options from a **web** app registration in your project - verify in the console and in the generated `firebase_options.dart`.
- Complete the spike in section 0 before depending on Windows cloud sync.

## 5. Enable Authentication

Console -> **Build -> Authentication -> Get started -> Sign-in method -> Email/Password -> Enable**. Optionally customize the password-reset email template and set its language to Arabic (Authentication -> Templates).

## 6. Create Cloud Firestore

Console -> **Build -> Firestore Database -> Create database**.

- Mode: **production mode** (locked down); the real rules are deployed in step 9.
- Location: pick the region closest to your users. **The location cannot be changed later.**

## 7. Run the FlutterFire CLI and generate configuration files

From the project root:

```bash
flutterfire configure \
  --project=<your-firebase-project-id> \
  --platforms=android,windows \
  --out=lib/firebase/firebase_options.dart
```

This generates/updates:

- `lib/firebase/firebase_options.dart` (the currently empty file),
- `android/app/google-services.json` and the Gradle wiring,
- `firebase.json` (CLI metadata).

Then initialize in `lib/firebase/firebase_initializer.dart` using the generated `DefaultFirebaseOptions.currentPlatform`, guarded by `firebase_platform_support.dart`.

**Commit policy:** `google-services.json` and `firebase_options.dart` are client configuration, not secrets - Firebase security comes from Auth + `firestore.rules`. They are tracked by default; if your team prefers not to commit them, add them to `.gitignore` and document how to regenerate. **Never** commit or bundle service-account keys, `*-firebase-adminsdk-*.json` files or the Admin SDK - the `.gitignore` already blocks the common names.

## 8. Add Firestore to `firebase.json`

Add this section (keep the keys the CLI generated):

```json
{
  "firestore": {
    "rules": "firestore.rules",
    "indexes": "firestore.indexes.json"
  }
}
```

## 9. Security rules and indexes

`firestore.rules` is a restrictive, documented template (owner-only access under `users/{userId}`, integer-money validation, no hard deletes, version checks). It was written without running the emulator, so:

1. Run the emulator: `firebase emulators:start --only auth,firestore`.
2. Write rules tests (`@firebase/rules-unit-testing`): owner allowed, other user denied, invalid money denied, hard delete denied, version rules.
3. Deploy: `firebase deploy --only firestore:rules,firestore:indexes`.

`firestore.indexes.json` is valid and empty - no composite indexes are needed because all filtering happens locally (see `database_schema.md`).

## 10. Development tips

- Use a **separate Firebase project** (or the emulator) for development; never test destructive scenarios against production data.
- Re-check Windows status and plugin versions at each Flutter BoM upgrade (`https://firebase.google.com/support/release-notes/flutter`).
- Evaluate App Check later; check its current Windows support first.
- Optional: enable Firestore usage/billing alerts in the Google Cloud console.

## 11. Verification checklist

- [ ] Sign up / sign in / sign out / password reset on Android
- [ ] Same on Windows
- [ ] Session persists after app restart (Android and Windows)
- [ ] A second user cannot read the first user's data
- [ ] Offline writes sync after reconnect, without duplicates
- [ ] No service-account key or Admin SDK anywhere in the repo or in the built app
