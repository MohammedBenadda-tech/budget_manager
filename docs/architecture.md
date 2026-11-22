# Architecture

Budget Manager uses a **feature-first Clean Architecture** with an **offline-first** data flow. This document explains the layers, the dependency rules, state management, dependency injection and the two abstraction boundaries (database and Firebase). Status: design only - no code is implemented yet.

## 1. Clean Architecture in this project

Code is divided into three layers per feature. Each layer only knows about the layer(s) inside it.

| Layer | Contains | May import | Must NOT import |
|---|---|---|---|
| **Domain** (`domain/`) | Entities, repository **interfaces**, use cases | Plain Dart, `core/utils` (e.g. `Money`), `core/errors` | Flutter, Riverpod, Drift, Firebase, any `data/` or `presentation/` code |
| **Data** (`data/`) | Local datasources (Drift DAOs wrappers), models (DTO/row mappers), repository **implementations** | Domain of the same feature, `core/database`, `core/synchronization` | Flutter widgets, `presentation/`, Firebase packages |
| **Presentation** (`presentation/`) | Pages, widgets, Riverpod providers/controllers | Domain (entities, use cases), `core/widgets`, `app/theme` | Data layer classes, Drift, Firebase |

**Dependency direction:** `presentation -> domain <- data`. The domain layer is the stable centre; both outer layers depend on it, never the other way round. Repository interfaces live in `domain/` and are implemented in `data/`, which is what lets us swap implementations (and fake them in tests).

## 2. Feature-first organization

Code is grouped by **feature** (`wallets`, `transactions`, `transfers`, ...) rather than by technical type. Every feature has the same internal shape:

```
features/<feature>/
├── data/          datasources/  models/  repositories/
├── domain/        entities/     repositories/  usecases/
└── presentation/  pages/        widgets/       providers/
```

Cross-feature rules:

- A feature may depend on **another feature's `domain/`** (e.g. `transactions` uses the `Wallet` and `Category` entities / IDs), never on its `data/` or `presentation/`.
- Aggregations that span features (wallet balances, monthly totals, category breakdowns) are SQL read-model queries in `core/database/daos/` (`balances_dao`, `analytics_dao`) exposed through the consuming feature's own repository (`dashboard`, `analytics`). This avoids features reaching into each other's tables.
- Anything used by more than one feature and not business-specific goes in `core/`.

## 3. The `core/` directory

| Folder | Responsibility |
|---|---|
| `constants/` | Currency, default categories (fixed IDs), sync tuning constants |
| `errors/` | `Failure` hierarchy (domain-level), exceptions (data-level), mapping between them |
| `utils/` | `Money` (integer minor units), formatters, date helpers, `Result`, logger, ID generator (UUID v7) |
| `extensions/` | Small extension methods (context, dates, strings, money) |
| `network/` | `ConnectivityService` - a thin wrapper over `connectivity_plus` exposing a stream of online/offline |
| `database/` | Drift database: tables, DAOs, enum converters, migrations, seeds |
| `synchronization/` | Sync engine, outbox, entity handlers, remote gateway **interface**, status providers |
| `services/` | Clock (injectable for tests), device identity, app lifecycle hooks |
| `dependency_injection/` | Riverpod providers that wire concrete implementations together |
| `widgets/` | Reusable, business-agnostic widgets (money text, amount field, empty/error views, sync indicator) |

## 4. Writes and reads (data flow)

**Write (e.g. add an expense):**

1. A page calls a controller (`presentation/providers`) which calls a **use case** (`domain/usecases`).
2. The use case validates business rules (amount > 0, wallet and category exist, ...) and calls the **repository interface**.
3. The repository implementation (`data/repositories`) opens **one Drift transaction** that (a) writes the entity row and (b) inserts a `sync_operation` row into the outbox. Either both persist or neither does.
4. The UI updates immediately from Drift's reactive queries (`watch...` streams). No network is involved.
5. The sync engine (independent of UI and features) picks up pending operations and pushes them via the `RemoteSyncGateway` when online.

**Read:** presentation providers expose `Stream`s from use cases -> repositories -> Drift `watch` queries. The UI never reads Firestore directly; remote changes reach the screen by being pulled into SQLite first.

## 5. State management - Riverpod

Choice: **Riverpod** (`flutter_riverpod` 3.x), without code generation to start (keeps the toolchain smaller; `riverpod_generator` can be added later if wanted).

Organization:

- Each feature's `presentation/providers/` holds:
  - `<feature>_providers.dart` - read-side providers (`StreamProvider`/`FutureProvider` wrapping use cases).
  - `<feature>_form_controller.dart` / `<feature>_controller.dart` - write-side `Notifier`/`AsyncNotifier` classes that call use cases and expose `AsyncValue` state.
  - Filter/UI-state providers (e.g. `transaction_filter_provider.dart`).
- Providers depend on **use cases**, use cases depend on **repository interfaces**. Concrete repository implementations are bound in `core/dependency_injection/repository_providers.dart`.
- Widgets are `ConsumerWidget`s. They contain no business logic, SQL or Firebase calls.
- Keep controllers small; business rules belong in use cases so they stay testable without Flutter.

## 6. Dependency injection

Riverpod providers **are** the DI container; no separate service locator (`get_it`) is used.

- `core/dependency_injection/database_providers.dart` - the `AppDatabase` singleton and DAO providers.
- `.../firebase_providers.dart` - selects the cloud implementation: `AuthRemoteDataSource` and `RemoteSyncGateway` are chosen per platform/config (FlutterFire implementation by default, REST implementation as the Windows fallback, no-op/fake implementation for tests or when signed out).
- `.../repository_providers.dart` - binds each repository interface to its implementation.
- `.../sync_providers.dart` - sync engine, scheduler, status provider.
- `.../service_providers.dart`, `.../core_providers.dart` - clock, connectivity, device identity, logger.
- `.../provider_overrides.dart` - the override list used by tests and by `app/bootstrap` to inject platform-specific objects.

Tests replace implementations with `ProviderScope(overrides: [...])` or `ProviderContainer(overrides: [...])`.

## 7. Database abstraction

- **Drift/SQLite is the local source of truth** on Android and Windows (opened through `drift_flutter`, so the same code runs on both).
- Only `core/database/` and the `data/datasources/` + `data/repositories/` classes may import Drift. **Domain entities never contain Drift types**; `data/models/` map between Drift rows (and Firestore maps) and domain entities.
- Each feature's `*_local_datasource.dart` wraps the relevant DAO(s). Repositories orchestrate datasources and the outbox recorder.
- Schema changes go through `core/database/migrations/` with `schemaVersion` bumps; snapshots in `drift_schemas/` back migration tests.
- Money columns are integers (minor units). No `double` anywhere in financial paths (see `database_schema.md`).

## 8. Firebase abstraction

Goal: if FlutterFire's Windows support proves unsuitable, only `lib/firebase/` and one provider file change.

**Rule: only files under `lib/firebase/` may import `firebase_core`, `firebase_auth` or `cloud_firestore`.** Everything else depends on these interfaces:

| Interface | Defined in | Purpose |
|---|---|---|
| `AuthRemoteDataSource` | `features/authentication/data/datasources/` | register, sign in/out, password reset, auth-state stream, current user |
| `RemoteSyncGateway` | `core/synchronization/domain/` | push one operation (idempotent), pull changes since a cursor, optional change notifications |

Implementations (all under `lib/firebase/`):

| Implementation | Path | Notes |
|---|---|---|
| FlutterFire auth | `auth/firebase_auth_remote_datasource.dart` | Default on Android; first thing to spike on Windows |
| FlutterFire Firestore gateway | `firestore/firestore_remote_sync_gateway.dart` (+ `firestore_document_codec`, `firestore_change_listener`) | Default on Android |
| REST auth + Firestore gateway | `rest/rest_auth_remote_datasource.dart`, `rest/rest_firestore_remote_sync_gateway.dart`, `rest/rest_http_client.dart` | **Optional fallback** for Windows using the Identity Toolkit and Firestore REST APIs with the user's own ID token. Polling instead of listeners. Build only if the FlutterFire spike fails. |

Supporting files: `firebase_initializer.dart` (guarded `Firebase.initializeApp`), `firebase_platform_support.dart` (a single place that answers "is FlutterFire acceptable on this platform?"), `firestore_collection_paths.dart` and `firestore_field_names.dart` (path/field constants so names are not scattered), `firebase_options.dart` (generated by FlutterFire CLI).

Security boundary: the app only ever holds **end-user credentials** (Firebase Auth ID tokens). The Firebase Admin SDK and service-account keys must never be bundled in the app; authorization is enforced by `firestore.rules`.

## 9. Cross-cutting conventions

- **Errors:** the data layer throws exceptions; repositories convert them to `Failure`s; use cases return `Result<T>` (success value or `Failure`) and do not throw for expected errors. The UI maps failures to Arabic messages.
- **Time:** never call `DateTime.now()` directly; use `ClockService` so tests and sync logic are deterministic. Store instants in UTC.
- **IDs:** UUID v7 generated on the client (`id_generator.dart`); the same ID is the SQLite primary key and the Firestore document ID.
- **Naming:** `snake_case.dart` files; suffixes `_page` (pages), `_providers` / `_controller` (state), `_repository` / `_repository_impl`, `_local_datasource`, `_model`, `_dao`, `_table`. Widgets are named for what they show (`wallet_card.dart`), without a `_widget` suffix. Use cases are named as verb phrases (`create_wallet.dart` -> `CreateWallet`, invoked via `call()`). The transaction entity is `FinancialTransaction` to avoid clashing with Drift's and Firestore's `Transaction` types.
- **Localization / RTL:** the app is Arabic-only at first; `app/localization/localization_config.dart` holds locale + delegates, and layouts must use directional (`start`/`end`) APIs.
- **Testing:** domain and sync logic are pure Dart and unit-tested with in-memory Drift databases and a fake `RemoteSyncGateway`; Firestore rules are tested with the emulator.

## 10. Where this differs from the suggested structure

Every deviation from the structure in the project brief is listed in [`project_structure.md`](project_structure.md#changes-from-the-suggested-structure).
