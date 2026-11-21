## 1.1.0

* `FirestoreDatabase.update()` creates a missing document instead of throwing
  `not-found`, like every other backend.
* `query` keeps a document's own `id` field instead of overwriting it.
* `FirestoreCursor` keeps microsecond precision (built from the raw
  `Timestamp`), so the boundary document is not fetched again on every pull.
* A failure to read anchors back after a successful commit no longer reports
  the pushed items as failed.
* Pushes larger than 500 operations are split into several commits.
* `failed-precondition` (usually a missing index) maps to `permanent`.

* Added `FirestoreSyncAdapter`, implementing the `ds_sync_contract`
  `SyncRemoteAdapter` interface for use with `ds_easy_db_sync`.
* Added `FirestoreCursor` (keyset delta cursor), `mapFirestoreError`,
  `anchorFrom` and `readTimestamp`.
* Delta pull via an indexed `updatedAt` field; keyset pagination on
  (`updatedAt`, document id) so rows sharing a timestamp are never skipped.
* `pushBatch` writes through an atomic `WriteBatch` and reads the
  server-assigned timestamps back as conflict anchors.
* Optional `deletedField` enables remote soft-deletes, which is what makes
  delta deletes possible at all.
* `resource-exhausted` maps to `SyncErrorKind.quotaExceeded`, so an exhausted
  quota reaches the application's `onQuotaExceeded` handler instead of being
  swallowed by a silent retry loop.
* Purely additive — `FirestoreDatabase` is unchanged and non-sync usage is
  unaffected.

## 1.0.1

* Added dartdoc comments to public API
* Added example documentation

## 1.0.0

* Initial release
* Cloud Firestore integration for EasyDB
* Cloud-hosted NoSQL database
* Offline support with automatic synchronization
* FirebaseOptions parameter for easy initialization
* Server timestamp support via FieldValue.serverTimestamp()
* Cross-platform support
