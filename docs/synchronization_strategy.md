# Synchronization strategy

Offline-first design for syncing the local SQLite database with Cloud Firestore across a single user's devices (Android and Windows). Status: design only. The sync layer lives in `lib/core/synchronization/` and is independent of the UI and of feature business logic; the only cloud-specific code is a `RemoteSyncGateway` implementation under `lib/firebase/`.

## 1. Goals and principles

- Every user action completes **against SQLite only**, instantly, with or without internet.
- Changes reach Firestore **automatically** later; remote changes reach SQLite automatically.
- **No data loss, no duplicates**, even with crashes, retries or app restarts mid-sync.
- Concurrent offline edits on two devices converge deterministically.
- The cloud implementation is **replaceable** (FlutterFire vs REST) without touching features.
- Firestore's built-in offline cache is **not** the offline mechanism (required on Windows). Recommended: disable Firestore persistence in the FlutterFire gateway so there is one cache (SQLite) and one queue (the outbox). Consequence: never rely on a Firestore write future completing while offline - the engine only pushes when online and applies timeouts.

## 2. Components

```
UI -> use case -> repository ──(1 SQLite transaction)──> entity row + sync_operations row
                                                                   │
        SyncScheduler (triggers) ──> SyncEngine ──> PushProcessor ─┤──> RemoteSyncGateway (interface)
                                          └──────> PullProcessor ──┘            │
                                          ConflictResolver, RetryPolicy         ▼
                                          SyncEntityHandler per entity      lib/firebase/ (FlutterFire or REST)
```

| Component | Responsibility |
|---|---|
| `OutboxRecorder` | Called by repositories inside their DB transaction; inserts the `sync_operation` |
| `SyncScheduler` / `SyncTrigger` | Decides when to run a sync cycle |
| `SyncEngine` | Orchestrates one cycle (push, then pull); single-flight (never two cycles at once); publishes `SyncState` |
| `PushProcessor` | Sends pending operations in order |
| `PullProcessor` | Fetches remote changes since the stored cursor and applies them |
| `ConflictResolver` | Implements the conflict policy (section 7) |
| `RetryPolicy` | Backoff schedule and error classification (section 5) |
| `SyncEntityHandler` + registry | Per entity: local row <-> remote map, validation, apply-to-local |
| `RemoteSyncGateway` | Interface: `push(operation)`, `pullChanges(collection, cursor, limit)`, optional `watchChanges()`; implemented in `lib/firebase/` |

## 3. Local-first writes

1. Use case validates and calls the repository.
2. Repository opens **one Drift transaction**: apply the change to the entity table (increment `version`, set `updated_at`, `updated_by_device`, `last_op_id`) **and** insert a `sync_operation` (`status = pending`, new `operation_id`, `base_version`, full `payload_json`). If either fails, both roll back - the outbox can never disagree with the data.
3. The transaction commits; Drift's streams update the UI immediately.
4. `SyncTrigger` fires ("local change"), debounced.

Optimization (optional): consecutive **pending** operations for the same entity may be coalesced into one (keep the first `base_version`, latest payload); a pending `create` followed by a `delete` can be dropped entirely.

## 4. Sync triggers

- After a local write (debounced ~1-2 s).
- When `ConnectivityService` reports online after being offline.
- App start and app resume.
- Periodic timer while the app is in the foreground (e.g. every few minutes) - mandatory on Windows REST fallback (no listeners).
- Manual "sync now" in Settings.

Connectivity is a hint, not truth: `connectivity_plus` says a network interface exists, not that Firestore is reachable. A failed request, not the connectivity flag, decides retry behaviour.

## 5. Pending operations, retry handling and states

Operation lifecycle: `pending` -> `in_progress` -> `synced`, or -> `failed`.

- **Order:** operations are processed in global `sequence` order. Parents therefore reach the cloud before children (wallet before its transactions; debt before repayments).
- **Push step (per operation):** mark `in_progress` (with a lease timestamp) -> `gateway.push(op)` -> on success mark `synced` (and later purge) -> on failure classify and reschedule.
- **Crash recovery:** on start, `in_progress` operations whose lease expired are reset to `pending`. Replays are safe because of idempotency (section 6).
- **Error classification:**

| Class | Examples | Action |
|---|---|---|
| Transient | no network, timeout, `unavailable`, `deadline-exceeded`, quota/backend busy | `failed` + `attempt_count++` + `next_retry_at` by exponential backoff with jitter (e.g. 5 s, 15 s, 1 min, 5 min, 15 min, then every hour); stop the cycle for this entity |
| Auth | token expired / user signed out | Pause sync; refresh token or ask the user to sign in again; do not burn attempts |
| Permanent | `permission-denied`, `invalid-argument`, validation failure | Mark `failed`, no automatic retry (`next_retry_at = null`), surface in Settings ("N changes need attention"), keep local data |
| Conflict | version mismatch | Hand to `ConflictResolver` (section 7) |

- **Ordering vs failure:** if an operation fails transiently, later operations for the **same entity** (and operations depending on it) wait; independent entities may continue. Simplest correct v1: stop the cycle at the first failed operation and retry later.
- **After max attempts** (e.g. 8) an operation stays `failed` until the user taps retry or it is superseded by a newer operation for the same entity.

## 6. Idempotency and duplicate prevention

Three layers, so retries and replays can never create duplicates or double-apply changes:

1. **Deterministic document IDs.** The document ID is the entity's client-generated UUID. A replayed `create` targets the same document; it can never create a second one.
2. **`operation_id` idempotency key.** Each operation carries a unique ID that is written into the document as `last_op_id`. The push is a **transactional read-compare-write**: read the remote document; if `remote.last_op_id == op.operation_id` the operation was already applied (e.g. crash after commit, before marking `synced`) -> mark `synced`, do nothing else.
3. **Optimistic concurrency.** The write sets `version = base_version + 1`; security rules require exactly "previous version + 1" on update and `1` on create, so a stale or duplicated write is rejected rather than silently overwriting.

Because balances are derived and transfers are single records, there are **no read-modify-write counters** to double-apply: replaying an operation never "adds money twice".

On the pull side, applying a remote change is also idempotent: changes with `version <= local.version` are ignored, and applying the same change twice yields the same row.

## 7. Conflict handling

A conflict exists when `remote.version != op.base_version` at push time (someone else changed the document), or when a pull brings a newer remote version for an entity that has a **pending local operation**.

Policy for v1 - **last writer wins per document, deterministic**:

1. Compare `updated_at` of the two versions; ties break on `updated_by_device` (lexicographic) so every device reaches the same result. (Device clocks can be wrong; this is an accepted v1 trade-off for a single-user app - the user's own devices are the only writers.)
2. If the local change wins: **rebase** - re-push with `base_version = remote.version`, so the new `version = remote.version + 1`.
3. If the remote change wins: apply the remote document to SQLite, mark the local operation `synced` (superseded) and record the event in a local conflict log (optional UI later: "a change made on another device replaced yours").
4. **Delete vs edit:** a tombstone is just another version, so the same rule applies (newer wins). A newer edit after a delete "resurrects" the record; a newer delete removes it. This is predictable and documented rather than silently special-cased.
5. Deleted records referenced by live records (e.g. a wallet tombstoned on device A while device B adds a transaction to it) are handled by the repair step in section 10.

What does **not** conflict thanks to the data model: two devices adding different income/expense transactions, transfers or repayments offline (different IDs, derived balances), and two devices setting the same month's budget (deterministic ID, simple LWW). Genuine conflicts are limited to two devices editing the same record.

Field-level merging is deliberately out of scope for v1.

## 8. Cross-device synchronization

**Pull** (per collection, in dependency order wallets -> categories -> transactions/transfers -> budgets -> savings -> debts -> repayments):

1. Read the stored cursor (`server_updated_at` high-water mark) from `sync_metadata`.
2. `gateway.pullChanges(collection, cursor, limit)` returns documents with `server_updated_at > cursor`, ordered, paged.
3. In **one Drift transaction**: for each change, ignore if it is our own echo (`last_op_id` matches a local operation) or `version <= local.version`; resolve conflicts if a pending operation exists for that entity; otherwise upsert (including tombstones); then advance the cursor. Cursor and data commit atomically, so a crash never skips changes.
4. Repeat until a page is smaller than the limit.

Clock skew does not matter for the cursor because it uses the **server** timestamp (`FieldValue.serverTimestamp()`, enforced by the security rules). Use a small overlap (re-read from `cursor - 1 ms` or handle equal timestamps with a tie-breaker on document ID) so documents written at the same server instant are not missed.

**Live updates:** where the gateway supports listeners (FlutterFire on Android) `watchChanges()` simply triggers a pull. Where it does not (REST fallback, possibly Windows) the periodic trigger polls.

**New device / first login:** local database is empty -> seed default categories -> full pull from cursor 0 -> normal operation. **Sign-out:** if unsynced operations exist, warn the user before clearing local data; otherwise clear the database and cursors so another account cannot see it.

## 9. Transfer consistency

A transfer is the clearest place where consistency matters; the design avoids the classic "debit one wallet, credit another" two-write problem entirely:

- A transfer is **one row / one Firestore document** with `source_wallet_id`, `destination_wallet_id`, `amount_minor`. There are no per-wallet balance writes.
- Both wallet balances change **because balances are derived** from the transfer record. They therefore change together, atomically, on every device, with no partial state possible.
- Creating/editing/deleting a transfer is **one outbox operation**, so it syncs atomically.
- The total balance cannot change: the amount is `+x` for the destination and `-x` for the source in the same derivation.
- Validation (use case `validate_transfer`): source != destination, amount > 0 (integer), both wallets exist, are not tombstoned and not archived. Enforced again by SQLite `CHECK` constraints and Firestore rules (`source != destination`, positive integer amount).
- Offline transfers behave exactly like any other offline write.

## 10. Repair step (referential races)

After a pull, a lightweight check finds live records that reference a tombstoned or missing parent (a rare multi-device race, e.g. device A deletes a wallet while device B adds a transaction to it). Recommended v1 handling: do not automatically restore the parent and do not drop the child; flag the child as `needs_attention`, show it under an "Unassigned" bucket, and let the user reassign or delete it. Financial records are never silently discarded.

## 11. Sync status for the UI

`SyncState` published by `sync_status_provider`: `idle(lastSyncedAt)`, `syncing`, `offline`, `paused(authRequired)`, `error(failedCount)`, plus the pending-operation count. Surfaces: `sync_status_indicator` widget, `offline_banner`, Settings `sync_status_tile`.

## 12. Platform notes

- **Android:** FlutterFire gateway with listeners; Firestore persistence disabled in favour of SQLite.
- **Windows:** FlutterFire Auth/Firestore are beta/development-only (see `firebase_setup.md`). Use the same gateway if the early spike passes; otherwise switch the provider to the REST gateway (polling, token refresh handled by `rest_auth_remote_datasource`). The sync engine does not change.
- Only end-user ID tokens are ever used in the app. **No Admin SDK or service-account credentials in the client.**

## 13. Testing plan

- Fake in-memory `RemoteSyncGateway` with controllable failures/latency; in-memory Drift; fake clock.
- Scenarios: offline create -> reconnect; crash between push success and marking `synced` (replay is a no-op); transient failure and backoff; permanent failure; two devices editing the same record; delete vs edit; two devices adding transactions concurrently; transfer round-trip and total-balance invariant; new-device full pull; pull cursor atomicity.
- Firestore rules tests with the emulator (valid/invalid money, version rules, ownership, no hard deletes).
