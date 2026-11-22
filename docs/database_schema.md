# Database schema

Planned structures for the **local SQLite database (Drift)** and **Cloud Firestore**. Status: design only; nothing is implemented. Field names are `snake_case` and identical in SQLite and Firestore unless noted.

## 1. Principles

1. **SQLite is the source of truth.** The UI reads and writes only SQLite. Firestore is the sync transport, backup and cross-device channel.
2. **Money is an integer in minor units.** DZD has 2 decimals, so `200000` = 2,000.00 DZD. Columns are named `*_minor`. No `double`/`num` in financial code; formatting converts with integer division/modulo (`core/utils/money.dart`). The amount of a transaction/transfer is **always positive**; direction comes from an explicit `type` (or from source/destination for transfers).
3. **Balances are derived, never stored.** A stored, mutable `balance` would be a lost-update hazard when two offline devices both change it. Balances are computed from the records (section 5), so concurrent offline entries on two devices merge without conflict.
4. **Transfers are their own record**, not two transactions and not income/expense. One row = one logical operation = one sync operation.
5. **Client-generated IDs.** Every entity ID is a UUID v7 created on the device (works offline, time-sortable). The same ID is the SQLite primary key and the Firestore document ID, which is how local and cloud records are associated - no mapping table.
6. **Soft deletes.** Deleting sets `deleted_at` (a tombstone) and syncs as an update; rows are purged locally only by a later cleanup job once the tombstone is synced.
7. **Timestamps** are UTC instants: SQLite `INTEGER` (epoch milliseconds), Firestore `Timestamp`.
8. **Ownership:** every synced record belongs to exactly one user. Locally the database belongs to the signed-in user; in Firestore everything lives under `users/{userId}/` and the rules only allow that user.

## 2. Common synchronization columns

Present on every synced table / document (a Drift mixin in `core/database/tables/sync_columns.dart`):

| Field | SQLite | Firestore | Required | Meaning |
|---|---|---|---|---|
| `id` | TEXT PK | doc ID + `id` field | yes | UUID v7 (fixed deterministic IDs for default categories) |
| `created_at` | INTEGER | Timestamp | yes | Creation instant (immutable) |
| `updated_at` | INTEGER | Timestamp | yes | Last modification instant (set by the device) |
| `deleted_at` | INTEGER NULL | Timestamp / null | no | Tombstone instant |
| `version` | INTEGER, default 1 | Number | yes | Incremented by 1 on every change; basis of conflict detection |
| `last_op_id` | TEXT | String | yes | `operation_id` of the last sync operation applied (idempotency / echo detection) |
| `updated_by_device` | TEXT | String | yes | Device ID that made the last change |
| `server_updated_at` | INTEGER NULL | Timestamp (`serverTimestamp()`) | cloud only | Server time of last write; pull cursor. Null locally until first pulled/pushed. |

## 3. Entities

Types below are Dart/Drift types; "Cloud" notes where Firestore differs. "Req" = required (NOT NULL).

### User  (`users/{userId}` document; local table `user_profile`, one row)

| Field | Type | Req | Notes |
|---|---|---|---|
| `uid` | TEXT PK | yes | Firebase Auth UID = `{userId}` |
| `email` | TEXT | yes | Copied from Auth for display |
| `display_name` | TEXT | no | |
| `currency_code` | TEXT | yes | `'DZD'` (single currency in v1; kept here, not per record) |
| `locale` | TEXT | yes | `'ar'` |
| `created_at`, `updated_at`, `version`, ... | | yes | Common sync columns |

Never stores passwords or tokens. Auth credentials are owned by Firebase Auth.

### Wallet  (`wallets`)

| Field | Type | Req | Notes |
|---|---|---|---|
| `name` | TEXT | yes | User-chosen, 1-60 chars; no predefined wallet types |
| `description` | TEXT | no | |
| `opening_balance_minor` | INTEGER | yes, default 0 | Balance before any recorded operation (can be negative) |
| `is_archived` | BOOL | yes, default false | Hides a wallet that has history |
| `sort_order` | INTEGER | yes, default 0 | Local ordering (synced) |
| + common sync columns | | | |

No limit on the number of wallets. **Open decision:** deleting a wallet that still has live transactions/transfers - recommended policy: only allow delete when empty, otherwise offer archive.

### Transaction  (`transactions`; domain entity `FinancialTransaction`)

| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | TEXT enum `income` / `expense` | yes | Explicit direction |
| `amount_minor` | INTEGER | yes | `> 0` (CHECK) |
| `category_id` | TEXT | yes | -> Category (default or custom). Category `type` must equal transaction `type` (domain rule) |
| `wallet_id` | TEXT | yes | -> Wallet |
| `description` | TEXT | no | Also searched by "search transactions" |
| `transaction_date` | INTEGER | yes | The date the money moved (user-editable) |
| `month_key` | INTEGER | yes | `yyyymm` of `transaction_date` in the user's local time zone; denormalized for fast monthly aggregates and budget calculation; recomputed when the date changes |
| + common sync columns (`created_at` = creation timestamp, `updated_at` = last update timestamp) | | | |

### Transfer  (`transfers`)

| Field | Type | Req | Notes |
|---|---|---|---|
| `source_wallet_id` | TEXT | yes | -> Wallet |
| `destination_wallet_id` | TEXT | yes | -> Wallet; `CHECK (source_wallet_id <> destination_wallet_id)` |
| `amount_minor` | INTEGER | yes | `> 0` (CHECK) |
| `transfer_date` | INTEGER | yes | |
| `description` | TEXT | no | |
| + common sync columns | | | |

### Category  (`categories`)

| Field | Type | Req | Notes |
|---|---|---|---|
| `type` | TEXT enum `income` / `expense` | yes | |
| `name` | TEXT | yes for custom | Display name of a custom category |
| `name_key` | TEXT | yes for defaults | Localization key of a default category (e.g. `category_expense_food`) |
| `is_default` | BOOL | yes | |
| `icon_key` | TEXT | no | |
| `color_value` | INTEGER | no | ARGB int |
| `is_archived` | BOOL | yes, default false | Categories in use are archived, not deleted |
| `sort_order` | INTEGER | yes | |
| + common sync columns | | | |

**Default categories** (income: salary, freelance, business, gift, other; expense: food, transport, education, health, shopping, entertainment, bills, other) are **seeded locally on every device with fixed deterministic IDs** (e.g. `default_expense_food`) by `core/database/seeds/default_data_seeder.dart`, and are **not synced** (they never enter the outbox and are not stored in Firestore). Because every device seeds identical IDs, a synced transaction referencing `default_expense_food` resolves everywhere, and two devices can never create duplicate defaults. Only **custom** categories sync. Editing/deleting defaults is disabled in v1.

### Budget  (`budgets`)

One **global** monthly budget (no per-wallet or per-category budgets in v1).

| Field | Type | Req | Notes |
|---|---|---|---|
| `id` | TEXT PK | yes | Deterministic: the month key, e.g. `2026-11`. Two devices setting the same month converge on one document |
| `month_key` | INTEGER | yes | `yyyymm` |
| `amount_minor` | INTEGER | yes | `>= 0` |
| + common sync columns | | | |

The budget in force for a month is the row for that month, or else the latest row for an earlier month (so setting it once carries forward; changing it later does not rewrite past months).

### SavingsGoal  (`savings_goals`)

| Field | Type | Req | Notes |
|---|---|---|---|
| `name` | TEXT | yes | |
| `target_amount_minor` | INTEGER | yes | `> 0` |
| `saved_amount_minor` | INTEGER | yes, default 0 | `>= 0`, user-maintained in v1 (progress = saved / target, integer maths) |
| `target_date` | INTEGER | no | |
| `note` | TEXT | no | |
| + common sync columns | | | |

**Assumption for v1:** saving towards a goal does **not** move money out of a wallet (it is tracking only). A future "contributions" ledger would be the conflict-free upgrade (derived total instead of a stored amount).

### Debt  (`debts`)

| Field | Type | Req | Notes |
|---|---|---|---|
| `direction` | TEXT enum `i_owe` / `owed_to_me` | yes | Distinguishes the two kinds of debt |
| `counterparty_name` | TEXT | yes | Person or entity |
| `principal_minor` | INTEGER | yes | `> 0` |
| `description` | TEXT | no | |
| `debt_date` | INTEGER | yes | |
| `due_date` | INTEGER | no | |
| + common sync columns | | | |

`remaining = principal - sum(live repayments)`; a debt is settled when `remaining = 0` (derived, not stored).

### DebtRepayment  (`debt_repayments`)

| Field | Type | Req | Notes |
|---|---|---|---|
| `debt_id` | TEXT | yes | -> Debt |
| `amount_minor` | INTEGER | yes | `> 0`; domain rule: total repayments should not exceed principal (two offline devices could still overshoot - surface as a warning) |
| `repayment_date` | INTEGER | yes | |
| `note` | TEXT | no | |
| + common sync columns | | | |

**Assumption for v1:** debts and repayments do **not** change wallet balances (no wallet link). If you later want that, add a nullable `wallet_id` and create a matching transaction in the same Drift transaction.

### SyncOperation  (local only: `sync_operations`, the outbox)

| Field | Type | Req | Notes |
|---|---|---|---|
| `sequence` | INTEGER PK AUTOINCREMENT | yes | Global processing order (FIFO) |
| `operation_id` | TEXT UNIQUE | yes | UUID v7 - the **idempotency key** |
| `entity_type` | TEXT enum | yes | wallet, transaction, transfer, category, budget, savings_goal, debt, debt_repayment, user_profile |
| `entity_id` | TEXT | yes | |
| `operation_type` | TEXT enum `create` / `update` / `delete` | yes | `delete` = tombstone update |
| `payload_json` | TEXT | yes | Full snapshot of the document to write (money as integers) |
| `base_version` | INTEGER | yes | Version of the remote doc this change was based on (0 for create) |
| `status` | TEXT enum | yes | `pending`, `in_progress`, `synced`, `failed` |
| `attempt_count` | INTEGER | yes, default 0 | |
| `next_retry_at` | INTEGER | no | Backoff schedule |
| `last_error` | TEXT | no | Truncated message/code |
| `created_at`, `updated_at` | INTEGER | yes | |
| `device_id` | TEXT | yes | |

### Local-only support tables

| Table | Purpose |
|---|---|
| `sync_metadata` | Key/value: this device's `device_id`, per-collection pull cursor (`server_updated_at` high-water mark), `last_sync_at`, schema/seed markers |
| `app_settings` | Theme mode and other device preferences (not synced in v1) |

## 4. Relationships

```
User 1 ──< Wallet 1 ──< Transaction >── 1 Category
                  │
                  ├──< Transfer (source_wallet_id)
                  └──< Transfer (destination_wallet_id)
User 1 ──< Budget (one per month_key)
User 1 ──< SavingsGoal
User 1 ──< Debt 1 ──< DebtRepayment
SyncOperation ──> any synced entity (entity_type + entity_id)
```

Foreign keys are enforced locally (`PRAGMA foreign_keys = ON`, `ON DELETE RESTRICT`; tombstones mean parents are never physically removed while children exist). Firestore has no foreign keys; the sync engine applies changes in global order (parent before child) and the repair step handles the rare cross-device race (see `synchronization_strategy.md`).

## 5. Derived values (single source of truth: SQL in `balances_dao` / `analytics_dao`)

All sums exclude rows with `deleted_at IS NOT NULL`.

```
wallet_balance(w) = opening_balance_minor(w)
                  + SUM(amount) of income    transactions in w
                  - SUM(amount) of expense   transactions in w
                  + SUM(amount) of transfers with destination = w
                  - SUM(amount) of transfers with source      = w

total_balance     = SUM(wallet_balance(w)) over non-deleted wallets
                  = SUM(opening) + SUM(income) - SUM(expense)      -- transfers cancel out

month_income / month_expense = SUM(amount) of transactions of that type with month_key = m
budget_remaining  = budget(m) - month_expense      (may be negative = overspent)
budget_consumed   = month_expense * 10000 / budget(m)   (basis points, integer division; guard budget = 0)
debt_remaining    = principal - SUM(live repayments)
```

**Invariant to test:** creating, editing or deleting a transfer never changes `total_balance`, and never appears in income/expense totals or budget spending.

## 6. Indexes

Local (Drift):

| Table | Index | Serves |
|---|---|---|
| `transactions` | `(wallet_id, transaction_date DESC)` | wallet detail list, balance sums |
| `transactions` | `(month_key, type)` | dashboard, budget, analytics |
| `transactions` | `(category_id)` | category filter / breakdown |
| `transactions` | `(deleted_at)` or partial `WHERE deleted_at IS NULL` | skipping tombstones |
| `transfers` | `(source_wallet_id)`, `(destination_wallet_id)` | balances |
| `debt_repayments` | `(debt_id)` | remaining debt |
| `sync_operations` | `(status, next_retry_at, sequence)`; unique `(operation_id)` | engine queue scans |
| all synced tables | `(updated_at)` | optional debugging / cleanup |

Search ("search transactions") starts as `LIKE` on `description` (+ category name join); move to SQLite FTS5 only if it becomes slow.

Firestore: **no custom composite indexes are needed** (`firestore.indexes.json` is empty). The only query is "documents in one collection where `server_updated_at` > cursor, ordered by `server_updated_at`", which single-field indexes (automatic) serve. All user-facing filtering/search/aggregation runs locally in SQLite, so Firestore never needs those indexes.

## 7. Firestore organization

```
users/{userId}                     <- profile document (email, display_name, currency_code, locale)
    wallets/{walletId}
    transactions/{transactionId}
    transfers/{transferId}
    categories/{categoryId}        <- custom categories only
    budgets/{yyyy-MM}
    savings_goals/{goalId}
    debts/{debtId}
    debt_repayments/{repaymentId}  <- flat (not nested under debts) so one query pulls all changes
```

Refinements vs. the suggested layout: the profile is the `users/{userId}` document itself rather than a `profile/` subcollection (one fewer level for a single record); `categories` holds only custom categories; `debt_repayments` stays flat. No balances are stored in Firestore.

## 8. Local vs cloud responsibilities

| Concern | SQLite (device) | Firestore (cloud) |
|---|---|---|
| Source of truth for the UI | **Yes** | No |
| Works offline | **Yes** | Not relied upon (Firestore's own offline cache is not used as the offline mechanism) |
| Queries, filters, search, aggregates, charts | **Yes** | No |
| Outbox / retry state / cursors | **Yes** (`sync_operations`, `sync_metadata`) | No |
| Cross-device propagation, backup | No | **Yes** |
| Authorization and shape validation | Domain use cases | **Security rules** |
| Default categories, app settings | Local only | Not stored |

## 9. Versioning and migration

- Local: Drift `schemaVersion` + step-by-step migrations in `core/database/migrations/`; snapshots in `drift_schemas/` for migration tests.
- Cloud: documents may carry `schema_version` when a breaking field change is needed; the codec in `lib/firebase/firestore/firestore_document_codec.dart` upgrades old documents on read. Prefer additive changes.
