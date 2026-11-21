import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ds_sync_contract/ds_sync_contract.dart';

/// A delta cursor that survives a restart and never skips a boundary row.
///
/// A bare timestamp is not enough: several documents can share the exact same
/// server timestamp, and a page that ends in the middle of such a group would
/// either lose the rest (`>`) or repeat the whole group forever (`>=`). Pairing
/// the timestamp with the last document id makes the cursor a true keyset
/// position, so `startAfter([timestamp, id])` continues exactly where the last
/// page stopped.
///
/// The timestamp is kept with **microsecond** precision, which is what
/// Firestore stores. A millisecond cursor would sit *before* the last document
/// of a page, so that document — and every other one in the same millisecond —
/// would be fetched again on every pull, and a page consisting only of such
/// documents would never advance at all.
///
/// It serialises to a single `String`, which is one of the primitive types the
/// sync metadata store can persist on both Hive and SQLite.
class FirestoreCursor {
  /// Creates a keyset cursor from a `DateTime`.
  ///
  /// On the web a `DateTime` only has millisecond precision; prefer
  /// [FirestoreCursor.fromTimestamp] when a Firestore `Timestamp` is at hand.
  FirestoreCursor({required DateTime updatedAt, required this.docId})
      : microsecondsSinceEpoch = updatedAt.microsecondsSinceEpoch;

  /// Creates a keyset cursor from the exact value Firestore returned.
  FirestoreCursor.fromTimestamp(Timestamp timestamp, {required this.docId})
      : microsecondsSinceEpoch = timestamp.microsecondsSinceEpoch;

  const FirestoreCursor._(this.microsecondsSinceEpoch, this.docId);

  /// The `updatedAt` value of the last document of the previous page.
  final int microsecondsSinceEpoch;

  /// The id of that document — the tie-breaker within one timestamp.
  final String docId;

  /// [microsecondsSinceEpoch] as a UTC `DateTime`.
  DateTime get updatedAt =>
      DateTime.fromMicrosecondsSinceEpoch(microsecondsSinceEpoch, isUtc: true);

  /// [microsecondsSinceEpoch] as the Firestore value used in `startAfter`.
  Timestamp get timestamp =>
      Timestamp.fromMicrosecondsSinceEpoch(microsecondsSinceEpoch);

  /// Separator between the two parts. Chosen because a Firestore document id
  /// cannot contain it.
  static const String separator = '/';

  /// Encodes the cursor as `<unixMicros>/<docId>`.
  String encode() => '$microsecondsSinceEpoch$separator$docId';

  /// Decodes a cursor produced by [encode].
  ///
  /// Returns `null` for anything unparseable — including a `null` cursor. The
  /// caller then starts from the beginning, which is expensive but never
  /// wrong.
  static FirestoreCursor? decode(Object? raw) {
    if (raw is FirestoreCursor) return raw;
    if (raw is! String) return null;

    final split = raw.indexOf(separator);
    if (split <= 0 || split == raw.length - 1) return null;

    final micros = int.tryParse(raw.substring(0, split));
    if (micros == null) return null;

    return FirestoreCursor._(micros, raw.substring(split + 1));
  }

  @override
  String toString() => 'FirestoreCursor(${encode()})';
}

/// Translates Firestore failures into the engine's vocabulary.
///
/// This mapping is also the connectivity check: anything that means "the
/// backend could not be reached" has to come out as
/// [SyncErrorKind.transient], because the engine has no other way to tell an
/// outage from a rejection — and no connectivity plugin is involved.
SyncError mapFirestoreError(Object error, StackTrace stackTrace) {
  if (error is SyncError) return error;

  if (error is FirebaseException) {
    final kind = _kindForCode(error.code);
    return SyncError(
      kind,
      message: '[${error.code}] ${error.message ?? ''}'.trim(),
      cause: error,
      stackTrace: stackTrace,
    );
  }

  if (error is SocketException || error is HttpException) {
    return SyncError(
      SyncErrorKind.transient,
      message: 'The backend could not be reached.',
      cause: error,
      stackTrace: stackTrace,
    );
  }

  // Unknown failures are treated as transient rather than permanent: retrying
  // a recoverable outage costs a round trip, while giving up on one strands
  // the record until the app intervenes.
  return SyncError(
    SyncErrorKind.transient,
    message: 'Unclassified backend failure.',
    cause: error,
    stackTrace: stackTrace,
  );
}

SyncErrorKind _kindForCode(String code) {
  switch (code) {
    case 'unavailable':
    case 'deadline-exceeded':
    case 'cancelled':
    case 'internal':
    case 'aborted':
      return SyncErrorKind.transient;

    // Firestore reports both throughput limits and exhausted project quota
    // under this one code. It is mapped to quotaExceeded so the application's
    // onQuotaExceeded handler is reached: an exhausted quota needs a decision
    // (upgrade, wait, stop syncing) that backing off silently cannot make.
    // The handler can still answer SyncResolution.leaveDirty to get the
    // ordinary backoff behaviour for a mere throughput spike.
    case 'resource-exhausted':
      return SyncErrorKind.quotaExceeded;

    case 'unauthenticated':
    case 'permission-denied':
      return SyncErrorKind.unauthorized;

    case 'not-found':
      return SyncErrorKind.notFound;

    case 'already-exists':
      return SyncErrorKind.conflict;

    // The adapter sends no write preconditions, so this code means the query
    // itself was rejected — almost always a missing composite index on
    // (updatedAt, __name__). Retrying cannot fix that; it has to reach the
    // application, whose log then shows Firestore's link to create the index.
    case 'failed-precondition':
    case 'invalid-argument':
    case 'out-of-range':
    case 'unimplemented':
    case 'data-loss':
      return SyncErrorKind.permanent;

    default:
      return SyncErrorKind.transient;
  }
}

/// Reads the sync anchor out of a stored document.
///
/// Firestore keeps no per-document version, so the server timestamp in
/// [updatedAtField] is the only comparison value available. A document without
/// that field yields an empty anchor, which the engine treats as "no anchor" —
/// conflicts on it cannot be detected.
RemoteAnchor anchorFrom(Map<String, dynamic> data, String updatedAtField) {
  return RemoteAnchor(updatedAt: readTimestamp(data[updatedAtField]));
}

/// Converts whatever Firestore handed back for a timestamp field into UTC.
///
/// Accepts a Firestore `Timestamp`, a `DateTime`, epoch milliseconds, or an
/// ISO-8601 string — a collection written by different clients over the years
/// can contain any of them.
DateTime? readTimestamp(Object? value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate().toUtc();
  if (value is DateTime) return value.toUtc();
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }
  if (value is String) return DateTime.tryParse(value)?.toUtc();
  return null;
}
