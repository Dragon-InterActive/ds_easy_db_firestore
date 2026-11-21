import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ds_easy_db/ds_easy_db.dart';
import 'package:ds_sync_contract/ds_sync_contract.dart';

import 'firestore_sync_support.dart';

/// Makes Cloud Firestore usable as the `remote` side of a sync engine.
///
/// This is purely additive: [FirestoreDatabase] keeps working exactly as
/// before for apps that do not sync. Wire this adapter only when you actually
/// want offline-first behaviour.
///
/// ```dart
/// engine.configure(
///   local: db.cache!,
///   remote: FirestoreSyncAdapter(),
///   config: const SyncConfig(collections: ['tasks']),
/// );
/// ```
///
/// ## What the backend has to provide
///
/// Delta pull relies on an indexed `updatedAt` field plus a composite index
/// on (`updatedAt`, `__name__`) for the collection. The adapter stamps the
/// field with the server time on every push, so the app does not have to
/// write it. Documents written past the adapter (console, other clients)
/// need the field as well, or delta pulls will not see them.
///
/// Firestore keeps no per-document version and cannot report deleted
/// documents in a query, so:
/// - the only conflict anchor is the server timestamp
///   ([SyncCapabilities.supportsTimestamps]);
/// - [SyncCapabilities.supportsDeltaDeletes] is only true when [deletedField]
///   is configured, i.e. when the collection marks deletions with a flag
///   instead of removing the document. Otherwise the engine degrades to full
///   pulls, because a query simply cannot return what is no longer there.
class FirestoreSyncAdapter implements SyncRemoteAdapter {
  /// Creates an adapter over [firestore] (defaults to the default instance).
  FirestoreSyncAdapter({
    FirebaseFirestore? firestore,
    this.updatedAtField = 'updatedAt',
    this.deletedField,
    this.pageSize = 200,
    this.fetchAnchorsAfterPush = true,
  })  : _firestore = firestore,
        assert(pageSize > 0, 'pageSize must be positive');

  final FirebaseFirestore? _firestore;

  /// The document field holding the server timestamp deltas are ordered by.
  ///
  /// Must be indexed. The adapter sets it to the server time on every push,
  /// so the backend — not the device — decides the value.
  final String updatedAtField;

  /// Optional boolean field marking a document as remotely deleted.
  ///
  /// Set this only if the collection uses remote soft-deletes. It is what
  /// makes [SyncCapabilities.supportsDeltaDeletes] possible: a hard-deleted
  /// document cannot appear in any query, so a delta pull can never report it.
  final String? deletedField;

  /// How many documents one pull page fetches.
  final int pageSize;

  /// Whether to read the server-assigned timestamps back after a push.
  ///
  /// Defaults to true, and costs one extra read per pushed document (batched
  /// by document id). Turning it off saves those reads but leaves the pushed
  /// records without a conflict anchor until the next pull — a concurrent edit
  /// in that window would go undetected.
  final bool fetchAnchorsAfterPush;

  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;

  @override
  SyncCapabilities get capabilities => SyncCapabilities(
        supportsTimestamps: true,
        supportsVersioning: false,
        supportsContentHash: false,
        supportsDeltaPull: true,
        supportsDeltaDeletes: deletedField != null,
        supportsBatchWrite: true,
      );

  @override
  SyncError mapError(Object error, StackTrace stackTrace) =>
      mapFirestoreError(error, stackTrace);

  @override
  Future<DeltaResult> pullSince(String collection, Object? cursor) async {
    try {
      final position = FirestoreCursor.decode(cursor);

      Query<Map<String, dynamic>> query = _db
          .collection(collection)
          .orderBy(updatedAtField)
          .orderBy(FieldPath.documentId);

      if (position != null) {
        // Keyset pagination: continue strictly after the last document of the
        // previous page, so rows sharing its timestamp are neither skipped nor
        // repeated endlessly.
        query = query.startAfter(
          <Object>[position.timestamp, position.docId],
        );
      }

      final snapshot = await query.limit(pageSize).get();
      if (snapshot.docs.isEmpty) {
        return DeltaResult(nextCursor: cursor);
      }

      final changed = <RemoteRecord>[];
      final deleted = <String>[];
      final flagField = deletedField;

      for (final doc in snapshot.docs) {
        final data = doc.data();
        if (flagField != null && data[flagField] == true) {
          deleted.add(doc.id);
          continue;
        }
        changed.add(RemoteRecord(
          id: doc.id,
          data: data,
          anchor: anchorFrom(data, updatedAtField),
        ));
      }

      final next = _cursorAt(snapshot.docs.last);

      return DeltaResult(
        changed: changed,
        deleted: deleted,
        // A document without a usable timestamp cannot advance the cursor;
        // keeping the old one re-reads that page instead of skipping past it.
        nextCursor: next?.encode() ?? cursor,
        hasMore: snapshot.docs.length == pageSize && next != null,
      );
    } catch (error, stackTrace) {
      throw mapFirestoreError(error, stackTrace);
    }
  }

  /// The keyset position right after [doc].
  ///
  /// Built from the raw Firestore `Timestamp` rather than a `DateTime`: on the
  /// web a `DateTime` drops the microseconds, and the cursor would land before
  /// [doc] instead of on it.
  FirestoreCursor? _cursorAt(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final raw = doc.data()[updatedAtField];
    if (raw is Timestamp) {
      return FirestoreCursor.fromTimestamp(raw, docId: doc.id);
    }
    final time = readTimestamp(raw);
    return time == null
        ? null
        : FirestoreCursor(updatedAt: time, docId: doc.id);
  }

  /// Firestore rejects a `WriteBatch` with more than 500 operations.
  static const int _maxBatchOperations = 500;

  @override
  Future<List<PushResult>> pushBatch(List<PushItem> items) async {
    if (items.isEmpty) return const <PushResult>[];

    // Larger pushes are split; each commit stays atomic on its own, and its
    // items share one status.
    final results = <PushResult>[];
    for (var offset = 0; offset < items.length; offset += _maxBatchOperations) {
      final end = (offset + _maxBatchOperations).clamp(0, items.length);
      results.addAll(await _commit(items.sublist(offset, end)));
    }
    return results;
  }

  Future<List<PushResult>> _commit(List<PushItem> items) async {
    try {
      final batch = _db.batch();
      for (final item in items) {
        final ref = _db.collection(item.collection).doc(item.id);
        if (item.isDelete) {
          final flagField = deletedField;
          if (flagField == null) {
            batch.delete(ref);
          } else {
            // Remote soft-delete, so the deletion itself is something a later
            // delta pull can report to other devices.
            batch.set(
              ref,
              <String, dynamic>{
                flagField: true,
                updatedAtField: FieldValue.serverTimestamp(),
              },
              SetOptions(merge: true),
            );
          }
          continue;
        }
        // The delta field is stamped on every write, whether or not the
        // document carries it: a stale or missing value would hide this
        // change from every other device's delta pull.
        batch.set(ref, <String, dynamic>{
          ..._resolveServerTimestamps(item.data!),
          updatedAtField: FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
    } catch (error, stackTrace) {
      // A Firestore batch is atomic: if the commit failed, nothing landed.
      // The uniform status across all items says exactly that, and the engine
      // keeps every one of them dirty.
      final syncError = mapFirestoreError(error, stackTrace);
      return <PushResult>[
        for (final item in items)
          PushResult(
            id: item.id,
            status: syncError.kind == SyncErrorKind.conflict
                ? PushStatus.conflict
                : PushStatus.failed,
            error: syncError,
          ),
      ];
    }

    // The commit landed. Reading the anchors back is a separate, optional
    // step: if it fails, the writes are still successful — they just carry no
    // conflict anchor until the next pull refreshes it.
    Map<String, RemoteAnchor> anchors;
    try {
      anchors = await _readBackAnchors(items);
    } catch (_) {
      anchors = const <String, RemoteAnchor>{};
    }

    return <PushResult>[
      for (final item in items)
        PushResult(
          id: item.id,
          status: PushStatus.success,
          newAnchor: anchors[_anchorKey(item.collection, item.id)],
        ),
    ];
  }

  /// Anchors are keyed by collection *and* id: one batch may contain the same
  /// id in two collections.
  static String _anchorKey(String collection, String id) => '$collection/$id';

  /// Reads the timestamps the server assigned during the push.
  ///
  /// The write itself cannot return them — `FieldValue.serverTimestamp()` is
  /// resolved on the backend — so they are fetched in id batches. Deletes are
  /// skipped: there is nothing left to anchor.
  Future<Map<String, RemoteAnchor>> _readBackAnchors(
    List<PushItem> items,
  ) async {
    if (!fetchAnchorsAfterPush) return const <String, RemoteAnchor>{};

    final wanted = <String, List<String>>{};
    for (final item in items) {
      if (item.isDelete && deletedField == null) continue;
      wanted.putIfAbsent(item.collection, () => <String>[]).add(item.id);
    }

    final anchors = <String, RemoteAnchor>{};
    for (final entry in wanted.entries) {
      // `whereIn` accepts at most 30 values per query.
      for (var offset = 0; offset < entry.value.length; offset += 30) {
        final chunk = entry.value.sublist(
          offset,
          (offset + 30).clamp(0, entry.value.length),
        );
        final snapshot = await _db
            .collection(entry.key)
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        for (final doc in snapshot.docs) {
          anchors[_anchorKey(entry.key, doc.id)] =
              anchorFrom(doc.data(), updatedAtField);
        }
      }
    }
    return anchors;
  }

  Map<String, dynamic> _resolveServerTimestamps(Map<String, dynamic> data) {
    return <String, dynamic>{
      for (final entry in data.entries)
        entry.key: entry.value == DatabaseRepository.serverTS
            ? FieldValue.serverTimestamp()
            : entry.value,
    };
  }
}
