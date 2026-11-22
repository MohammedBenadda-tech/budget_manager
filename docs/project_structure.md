# Project structure

Purpose of every major folder. For the exact file list see [`directory_tree.txt`](directory_tree.txt). All `.dart` files in this scaffold are intentionally empty.

## Top level

| Path | Purpose |
|---|---|
| `android/`, `windows/` | Flutter platform projects. Placeholders only - generate them as described in the README. |
| `assets/` | `images/`, `icons/`, `fonts/` (put your Arabic font files here and declare them in `pubspec.yaml`). |
| `docs/` | Design documentation (this folder). |
| `drift_schemas/` | Schema snapshots exported by `drift_dev schema dump`; used by migration tests. |
| `lib/` | All application code. |
| `test/` | Unit/widget tests mirroring `lib/` (`core/`, `features/<feature>/`, `helpers/`). |
| `firestore.rules`, `firestore.indexes.json` | Firestore security rules (restrictive template) and index definitions (none needed yet). |
| `pubspec.yaml`, `analysis_options.yaml`, `.gitignore`, `README.md` | Project configuration and entry documentation. |

## `lib/`

| Path | Purpose |
|---|---|
| `main.dart` | Entry point: ensure bindings, run bootstrap, start `ProviderScope` + app. |
| `app/app.dart` | Root `MaterialApp.router` widget (theme, locale, router). |
| `app/bootstrap/` | Start-up sequence (database open, seeding, optional Firebase init) and provider overrides. |
| `app/router/` | `go_router` config, route names/paths, auth redirect guard. |
| `app/shell/` | Navigation shell (bottom bar on Android, navigation rail on Windows) and destinations. |
| `app/theme/` | Light/dark themes, colors, typography, spacing tokens. |
| `app/localization/` | Locale and delegates configuration (Arabic, RTL). |
| `core/` | Shared infrastructure - see below. |
| `features/` | One folder per product module - see below. |
| `firebase/` | The only place allowed to import FlutterFire; also the optional REST adapters. |

### `core/`

| Path | Purpose |
|---|---|
| `constants/` | `app_constants`, `currency_constants` (DZD, minor-unit factor), `default_categories` (fixed IDs), `sync_constants` (batch size, backoff). |
| `errors/` | `failures`, `exceptions`, `error_mapper`. |
| `extensions/` | Context, date, money and string extensions. |
| `utils/` | `money` (value type over integer minor units), `money_formatter`, `date_utils`, `result`, `validators`, `app_logger`, `debouncer`, `platform_utils`, `id_generator`. |
| `network/` | `connectivity_service`, `network_status`. |
| `database/` | `app_database`, `database_connection`; `tables/` (one per entity + `sync_columns` mixin), `daos/` (per-entity DAOs + `balances_dao`, `analytics_dao` read models), `converters/`, `migrations/`, `seeds/default_data_seeder`. |
| `synchronization/domain/` | Sync vocabulary: `sync_operation`, status/type/entity enums, `remote_sync_gateway` (interface), `remote_change`, `sync_cursor`, `conflict_resolution`, `sync_state`. |
| `synchronization/engine/` | `sync_engine`, `sync_scheduler`, `sync_trigger`, `outbox_recorder`, `push_processor`, `pull_processor`, `retry_policy`, `conflict_resolver`. |
| `synchronization/handlers/` | One `*_sync_handler` per synced entity (local row <-> remote map) + registry. |
| `synchronization/providers/` | `sync_status_provider` for the UI. |
| `services/` | `clock_service`, `device_identity_service`, `app_lifecycle_service`. |
| `dependency_injection/` | Riverpod wiring (see `architecture.md`). |
| `widgets/` | Shared widgets: loading/error/empty views, money text, amount field, date picker field, text field, primary button, confirm dialog, section header, sync indicator, offline banner. |

### `firebase/`

| Path | Purpose |
|---|---|
| `firebase_options.dart` | Generated later by `flutterfire configure` (kept empty; never hand-edit, never invent values). |
| `firebase_initializer.dart`, `firebase_platform_support.dart` | Guarded initialization and per-platform capability switch. |
| `firestore_collection_paths.dart`, `firestore_field_names.dart` | Path and field-name constants. |
| `auth/` | FlutterFire implementation of `AuthRemoteDataSource`. |
| `firestore/` | FlutterFire implementation of `RemoteSyncGateway`, document codec, change listener. |
| `rest/` | Optional REST-based replacements for Windows. |

## Features

Every feature has `data/{datasources,models,repositories}`, `domain/{entities,repositories,usecases}`, `presentation/{pages,widgets,providers}`.

| Feature | Responsibility | Key domain concepts |
|---|---|---|
| `authentication` | Account lifecycle and session | `AppUser`, `AuthRepository` |
| `dashboard` | Financial overview (read-only aggregation) | `DashboardSummary`, `MonthlyTotals` |
| `wallets` | Wallet CRUD and balances | `Wallet`, `WalletWithBalance` |
| `transactions` | Income and expenses (one entity, explicit `TransactionType`), filters, search | `FinancialTransaction`, `TransactionFilter` |
| `transfers` | Wallet-to-wallet transfers (separate entity; never income/expense) | `Transfer`, transfer validation |
| `categories` | Default + custom categories | `Category`, `CategoryType` |
| `budgets` | Global monthly budget and status | `MonthlyBudget`, `BudgetStatus` |
| `analytics` | Weekly/monthly summaries, charts data, history | `PeriodSummary`, `CategoryExpenseTotal` |
| `savings` | Savings goals and progress | `SavingsGoal` |
| `debts` | Debts in both directions + repayments | `Debt`, `DebtRepayment`, `DebtDirection` |
| `settings` | Theme, account settings, category management entry, sync status | `AppSettings`, `ThemePreference` |

## Naming conventions

- Files: `snake_case.dart`. Pages `*_page.dart`, form controllers `*_form_controller.dart`, providers `*_providers.dart`.
- Data: `*_local_datasource.dart`, `*_model.dart`, `*_repository_impl.dart`; domain: `*_repository.dart` (interface), use cases as verb phrases.
- Drift: `*_table.dart`, `*_dao.dart`.

## Changes from the suggested structure

The suggested layout was kept as the base. These additions/refinements were made, each for a specific reason:

1. **`lib/firebase/` expanded** (`auth/`, `firestore/`, `rest/`, initializer, platform-support switch, path/field constants). Reason: the Windows Firebase support is beta, so all FlutterFire code and the optional REST fallback must live in one replaceable place.
2. **`core/database/` subdivided** into `tables/`, `daos/`, `converters/`, `migrations/`, `seeds/`. Reason: ten-plus tables plus migrations would otherwise become a few huge files.
3. **`core/synchronization/` subdivided** into `domain/`, `engine/`, `handlers/`, `providers/`. Reason: the sync layer must stay independent of UI and features; the `domain/` part defines the `RemoteSyncGateway` interface the Firebase layer implements.
4. **`app/bootstrap/` and `app/shell/` added.** Reason: start-up orchestration (DB, seeding, optional Firebase) and the adaptive Android/Windows navigation shell do not belong in `main.dart` or a feature.
5. **`drift_schemas/` added** for Drift schema snapshots (migration tests).
6. **`test/helpers/` added** and tests mirror `lib/core` subfolders.
7. **No `firebase.json` shipped.** `flutterfire configure` generates/updates it; `docs/firebase_setup.md` shows the Firestore section to add.
8. **Firestore layout refined:** the profile lives in the `users/{userId}` document itself instead of a `profile/` subcollection, and `categories` are synced only for custom categories (defaults are seeded locally with fixed IDs). Both are explained in `database_schema.md`.
9. **`.gitkeep` files** exist only in folders that contain no Dart files (`android/`, `windows/`, `assets/*`, `drift_schemas/`, `test/*`).
