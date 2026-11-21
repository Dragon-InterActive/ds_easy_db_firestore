import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ds_easy_db_firestore/ds_easy_db_firestore.dart';
import 'package:ds_sync_contract/ds_sync_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FirestoreCursor', () {
    test('round-trips through its persisted string form', () {
      final cursor = FirestoreCursor(
        updatedAt: DateTime.utc(2026, 6, 1, 12, 30),
        docId: 'task-42',
      );

      final decoded = FirestoreCursor.decode(cursor.encode())!;
      expect(decoded.updatedAt, cursor.updatedAt);
      expect(decoded.docId, cursor.docId);
    });

    test('encodes to a plain string the metadata store can persist', () {
      final encoded = FirestoreCursor(
        updatedAt: DateTime.utc(2026, 6, 1),
        docId: 'a',
      ).encode();

      expect(encoded, isA<String>());
      expect(encoded, '${DateTime.utc(2026, 6, 1).microsecondsSinceEpoch}/a');
    });

    test('keeps microsecond precision, so the cursor sits on the last document',
        () {
      // Firestore stores microseconds. A millisecond cursor would land before
      // this document and fetch it again on every pull.
      final timestamp = Timestamp(1780000000, 123456000);
      final cursor = FirestoreCursor.fromTimestamp(timestamp, docId: 'a');

      final decoded = FirestoreCursor.decode(cursor.encode())!;
      expect(decoded.timestamp, timestamp);
      expect(decoded.microsecondsSinceEpoch, 1780000000123456);
    });

    test('a DateTime cursor keeps its microseconds too', () {
      final at = DateTime.utc(2026, 6, 1, 12, 0, 0, 0, 789);
      final decoded = FirestoreCursor.decode(
        FirestoreCursor(updatedAt: at, docId: 'a').encode(),
      )!;
      expect(decoded.updatedAt, at);
    });

    test('keeps the document id, so a timestamp tie has a tie-breaker', () {
      final first = FirestoreCursor(
        updatedAt: DateTime.utc(2026, 6, 1),
        docId: 'a',
      );
      final second = FirestoreCursor(
        updatedAt: DateTime.utc(2026, 6, 1),
        docId: 'b',
      );

      expect(first.encode(), isNot(second.encode()));
    });

    test('a document id containing digits is not mistaken for the timestamp',
        () {
      final decoded = FirestoreCursor.decode('1780000000000/2026/report')!;
      expect(decoded.docId, '2026/report');
    });

    test('unparseable input restarts from the beginning instead of throwing',
        () {
      expect(FirestoreCursor.decode(null), isNull);
      expect(FirestoreCursor.decode(''), isNull);
      expect(FirestoreCursor.decode('no-separator'), isNull);
      expect(FirestoreCursor.decode('/only-id'), isNull);
      expect(FirestoreCursor.decode('123/'), isNull);
      expect(FirestoreCursor.decode(42), isNull);
    });
  });

  group('error mapping', () {
    SyncErrorKind kindOf(String code) => mapFirestoreError(
          FirebaseException(plugin: 'cloud_firestore', code: code),
          StackTrace.current,
        ).kind;

    test(
        'an unreachable backend is transient, so no connectivity plugin is '
        'needed', () {
      expect(kindOf('unavailable'), SyncErrorKind.transient);
      expect(kindOf('deadline-exceeded'), SyncErrorKind.transient);
      expect(
        mapFirestoreError(
          const SocketException('no route to host'),
          StackTrace.current,
        ).kind,
        SyncErrorKind.transient,
      );
    });

    test('auth failures are not retried as if they were outages', () {
      expect(kindOf('permission-denied'), SyncErrorKind.unauthorized);
      expect(kindOf('unauthenticated'), SyncErrorKind.unauthorized);
    });

    test('an exhausted quota reaches the dedicated handler, not just a backoff',
        () {
      // Firestore uses this one code for throughput limits and for a spent
      // project quota. The latter needs an application decision, so it must
      // not be swallowed by a silent retry loop.
      expect(kindOf('resource-exhausted'), SyncErrorKind.quotaExceeded);
    });

    test('rejections that retrying cannot fix are permanent', () {
      expect(kindOf('invalid-argument'), SyncErrorKind.permanent);
      expect(kindOf('unimplemented'), SyncErrorKind.permanent);
    });

    test('a missing index (failed-precondition) reaches the application', () {
      // The adapter sends no write preconditions, so this code means the
      // delta query was rejected — retrying would never fix it.
      expect(kindOf('failed-precondition'), SyncErrorKind.permanent);
    });

    test('an id that already exists is a conflict', () {
      expect(kindOf('already-exists'), SyncErrorKind.conflict);
    });

    test('an unknown code errs towards retrying', () {
      expect(kindOf('something-new-in-a-future-sdk'), SyncErrorKind.transient);
    });

    test('the original exception is preserved for logging', () {
      final original =
          FirebaseException(plugin: 'cloud_firestore', code: 'internal');
      final mapped = mapFirestoreError(original, StackTrace.current);

      expect(mapped.cause, same(original));
      expect(mapped.stackTrace, isNotNull);
      expect(mapped.message, contains('internal'));
    });

    test('an already-normalised error passes through untouched', () {
      const original = SyncError(SyncErrorKind.quotaExceeded);
      expect(mapFirestoreError(original, StackTrace.current), same(original));
    });
  });

  group('anchors', () {
    test('the anchor keeps the microseconds of the server timestamp', () {
      final anchor = anchorFrom(
        {'updatedAt': Timestamp(1780000000, 123456000)},
        'updatedAt',
      );

      expect(anchor.updatedAt!.microsecondsSinceEpoch, 1780000000123456);
    });

    test('reads a Firestore timestamp as the comparison anchor', () {
      final anchor = anchorFrom(
        {'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 6, 1, 12))},
        'updatedAt',
      );

      expect(anchor.updatedAt, DateTime.utc(2026, 6, 1, 12));
      expect(anchor.isEmpty, isFalse);
    });

    test('a document without the field yields an empty anchor', () {
      expect(anchorFrom({'title': 'x'}, 'updatedAt').isEmpty, isTrue);
    });

    test('accepts the timestamp shapes older clients may have written', () {
      final millis = DateTime.utc(2026, 6, 1).millisecondsSinceEpoch;
      expect(readTimestamp(millis), DateTime.utc(2026, 6, 1));
      expect(
          readTimestamp('2026-06-01T00:00:00.000Z'), DateTime.utc(2026, 6, 1));
      expect(readTimestamp(DateTime.utc(2026, 6, 1)), DateTime.utc(2026, 6, 1));
      expect(readTimestamp(null), isNull);
      expect(readTimestamp(<String>['nope']), isNull);
    });
  });

  group('capabilities', () {
    test('declares timestamps and delta pull, but no versioning', () {
      final capabilities = FirestoreSyncAdapter().capabilities;

      expect(capabilities.supportsTimestamps, isTrue);
      expect(capabilities.supportsDeltaPull, isTrue);
      expect(capabilities.supportsBatchWrite, isTrue);
      expect(capabilities.supportsVersioning, isFalse);
      expect(capabilities.supportsContentHash, isFalse);
    });

    test('delta deletes require a remote soft-delete flag', () {
      // A hard-deleted document cannot appear in a query, so without a flag
      // the engine has to fall back to full pulls.
      expect(
        FirestoreSyncAdapter().capabilities.supportsDeltaDeletes,
        isFalse,
      );
      expect(
        FirestoreSyncAdapter(deletedField: 'deleted')
            .capabilities
            .supportsDeltaDeletes,
        isTrue,
      );
    });
  });
}
