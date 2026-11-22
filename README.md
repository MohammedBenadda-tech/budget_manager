# Budget Manager

An offline-first personal finance and budget manager for **Android** and **Windows Desktop**, with an **Arabic (RTL)** interface and **Algerian Dinar (DZD)** as the default currency.

> **Status: architecture scaffold only.**
> This repository contains the folder structure, empty Dart source files, configuration and design documentation. **No application functionality has been implemented.** Every `.dart` file under `lib/` is intentionally a zero-byte file, including `lib/main.dart`, so `flutter run` will not work until you implement it. The scaffold is meant to be filled in step by step.

## Main features (planned)

| Module | What it will do |
|---|---|
| Authentication | Register, log in/out, password recovery, persistent sessions (Firebase Auth, email + password first, extensible) |
| Dashboard | Total balance, per-wallet balances, monthly income/expenses, remaining budget, recent transactions, charts |
| Wallets | Unlimited user-named wallets; create, edit, delete; per-wallet balance and transaction list |
| Income / Expenses | Add, edit, delete, filter by date/wallet/category, search; default categories now, custom categories later |
| Transfers | Move money between wallets as one atomic operation that is neither income nor expense |
| Budget | One global monthly budget: spent, remaining, percentage consumed |
| Analytics | Weekly/monthly summaries, income vs expenses, expense by category, monthly comparisons, history |
| Savings | Goals with target, saved amount and progress |
| Debts | Money I owe vs money owed to me, repayments, remaining balance, history |
| Settings | Arabic/RTL, DZD, light/dark theme, category management, account settings |
| Offline-first sync | Everything works offline; changes sync automatically to Firestore when connectivity returns |

## Technologies

- Flutter / Dart
- State management and dependency injection: **Riverpod**
- Routing: **go_router**
- Local database (source of truth): **SQLite via Drift** (same layer on Android and Windows)
- Cloud: **Firebase Authentication + Cloud Firestore** (isolated behind interfaces)
- Charts: `fl_chart`; connectivity: `connectivity_plus`; IDs: `uuid` (v7); formatting: `intl`

## Target platforms

| Platform | Local DB (Drift) | Firebase Auth / Firestore |
|---|---|---|
| Android | Supported | Supported |
| Windows | Supported | **Beta / development only** - see warning below |

> **Windows + Firebase warning.** Firebase's Flutter setup documentation lists Windows as *beta* for Authentication and Cloud Firestore, and the FlutterFire platform table marks Windows as "for development only; production on Windows is not supported". This project therefore keeps SQLite as the source of truth on every platform and hides all Firebase code behind interfaces so the Windows cloud connection can be replaced (for example with a REST-based implementation) without touching business logic. Details: [`docs/firebase_setup.md`](docs/firebase_setup.md).

## Architecture overview

Feature-first **Clean Architecture** with an offline-first data flow:

```
Presentation (pages, widgets, Riverpod providers)
        |  calls
        v
Domain (entities, repository interfaces, use cases)      <- no Flutter/Drift/Firebase imports
        ^  implemented by
        |
Data (local datasources on Drift, models, repository implementations)
        |  writes entity + outbox row in ONE SQLite transaction
        v
SQLite (Drift) = local source of truth  --->  Sync engine  --->  RemoteSyncGateway (interface)
                                                                       |
                                                    lib/firebase/  (the only place that imports FlutterFire)
```

Key rules: money is stored as integer minor units, balances are derived (never stored), transfers are single records, IDs are client-generated UUIDs, deletes are tombstones, and sync operations are idempotent. Full explanation in [`docs/`](docs/).

## Planned directory structure

```
budget_manager/
├── android/  windows/                 # platform scaffolding (see "Getting started")
├── assets/{images,icons,fonts}/
├── docs/                              # architecture, schema, sync, firebase setup, structure
├── drift_schemas/                     # exported Drift schema snapshots (migration tests)
├── lib/
│   ├── main.dart
│   ├── app/                           # app shell: bootstrap, router, theme, localization
│   ├── core/
│   │   ├── constants/ errors/ extensions/ utils/ network/ services/ widgets/
│   │   ├── database/                  # Drift: tables, daos, converters, migrations, seeds
│   │   ├── synchronization/           # domain, engine, handlers, providers (UI/Firebase independent)
│   │   └── dependency_injection/      # Riverpod provider wiring
│   ├── features/
│   │   └── <feature>/                 # authentication, dashboard, wallets, transactions, transfers,
│   │       ├── data/                  # categories, budgets, analytics, savings, debts, settings
│   │       │   └── datasources/ models/ repositories/
│   │       ├── domain/
│   │       │   └── entities/ repositories/ usecases/
│   │       └── presentation/
│   │           └── pages/ widgets/ providers/
│   └── firebase/                      # FlutterFire + REST adapters; firebase_options.dart (generated)
├── test/{core,features,helpers}/
├── firestore.rules  firestore.indexes.json
├── pubspec.yaml  analysis_options.yaml  .gitignore  README.md
```

The complete file-level tree is in [`docs/directory_tree.txt`](docs/directory_tree.txt); every folder's purpose is explained in [`docs/project_structure.md`](docs/project_structure.md).

## Prerequisites

- Flutter SDK (stable channel) with Dart 3.8 or newer - run `flutter doctor`
- Android: Android Studio + Android SDK
- Windows: Visual Studio 2022 with the **Desktop development with C++** workload (also required by the Firebase C++ SDK plugin build)
- Later, for cloud sync: a Firebase account, the Firebase CLI and the FlutterFire CLI (see [`docs/firebase_setup.md`](docs/firebase_setup.md))

## Getting started

1. **Generate the platform folders.** The `android/` and `windows/` folders contain only placeholders. Create a throwaway Flutter project and copy its platform folders over them:
   ```bash
   flutter create --platforms=android,windows --project-name budget_manager --org com.yourname temp_scaffold
   cp -r temp_scaffold/android/. android/
   cp -r temp_scaffold/windows/. windows/
   rm -rf temp_scaffold
   ```
   (Use your own `--org`; it becomes the Android application ID.)
2. `flutter pub get` - this scaffold's `pubspec.yaml` has not been resolved yet; fix any version constraint it reports (see the provenance comment inside the file).
3. Start implementing from the roadmap below. Local-only features need no Firebase setup.

## Roadmap

0. **Scaffold** (this repository).
1. **Foundation:** platform folders, theme (light/dark), Arabic localization + RTL, router, `Money` type, Drift database + migrations, default categories seeding. *Also run the Windows Firebase spike here* (sign-in, session persistence after restart, Firestore read/write) so you learn about Windows limitations early.
2. **Wallets and categories** (local only).
3. **Income and expenses** (transactions): forms, history, filters, search.
4. **Transfers** and the balance-derivation queries.
5. **Dashboard and monthly budget.**
6. **Authentication** (Firebase Auth behind `AuthRepository`).
7. **Sync engine:** outbox recording, push/pull, retry, conflict handling, sync status UI.
8. **Analytics, savings, debts, settings polish.**
9. **Hardening:** tests (sync scenarios, money invariants), Firestore rules tests with the emulator, release builds, Windows packaging.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) - layers, dependency rules, state management, DI, abstractions
- [`docs/database_schema.md`](docs/database_schema.md) - SQLite and Firestore structures, money and balance rules
- [`docs/synchronization_strategy.md`](docs/synchronization_strategy.md) - offline-first sync design
- [`docs/firebase_setup.md`](docs/firebase_setup.md) - Firebase setup steps and Windows limitations
- [`docs/project_structure.md`](docs/project_structure.md) - what every folder is for
