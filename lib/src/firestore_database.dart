import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ds_easy_db/ds_easy_db.dart';

class FirestoreDatabase implements DatabaseRepository {
  final FirebaseOptions? options;

  FirestoreDatabase({this.options});

  @override
  Future<void> init() async {
    if (Firebase.apps.isEmpty) {
      if (options == null) {
        throw Exception(
          'Firebase has not been initialized. Please provide FirebaseOptions '
          'in the FirestoreDatabase constructor or initialize Firebase manually.',
        );
      }
      await Firebase.initializeApp(options: options);
    }
  }

  @override
  Future<void> set(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    final processedData = data.map((key, value) {
      if (value == DatabaseRepository.serverTS) {
        return MapEntry(key, FieldValue.serverTimestamp());
      }
      return MapEntry(key, value);
    });

    await FirebaseFirestore.instance
        .collection(collection)
        .doc(id)
        .set(processedData);
  }

  @override
  Future<void> update(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    final processedData = data.map((key, value) {
      if (value == DatabaseRepository.serverTS) {
        return MapEntry(key, FieldValue.serverTimestamp());
      }
      return MapEntry(key, value);
    });

    await FirebaseFirestore.instance
        .collection(collection)
        .doc(id)
        .update(processedData);
  }

  @override
  Future<Map<String, dynamic>?> get(
    String collection,
    String id, {
    dynamic defaultValue,
  }) async {
    final doc = await FirebaseFirestore.instance
        .collection(collection)
        .doc(id)
        .get();

    if (!doc.exists) return defaultValue;
    return doc.data();
  }

  @override
  Future<Map<String, dynamic>?> getAll(String collection) async {
    final snapshot = await FirebaseFirestore.instance
        .collection(collection)
        .get();

    if (snapshot.docs.isEmpty) return null;

    final Map<String, dynamic> result = {};
    for (var doc in snapshot.docs) {
      result[doc.id] = doc.data();
    }

    return result;
  }

  @override
  Future<bool> exists(String collection, String id) async {
    final doc = await FirebaseFirestore.instance
        .collection(collection)
        .doc(id)
        .get();
    return doc.exists;
  }

  @override
  Future<bool> existsWhere(
    String collection, {
    required Map<String, dynamic> where,
  }) async {
    Query query = FirebaseFirestore.instance.collection(collection);
    for (var entry in where.entries) {
      query = query.where(entry.key, isEqualTo: entry.value);
    }
    final snapshot = await query.limit(1).get();
    return snapshot.docs.isNotEmpty;
  }

  @override
  Future<void> delete(String collection, String id) async {
    await FirebaseFirestore.instance.collection(collection).doc(id).delete();
  }

  @override
  Future<List<Map<String, dynamic>>> query(
    String collection, {
    Map<String, dynamic> where = const {},
  }) async {
    Query query = FirebaseFirestore.instance.collection(collection);

    for (var entry in where.entries) {
      query = query.where(entry.key, isEqualTo: entry.value);
    }

    final snapshot = await query.get();
    return snapshot.docs.map((doc) {
      final data = doc.data() as Map<String, dynamic>;
      data['id'] = doc.id;
      return data;
    }).toList();
  }
}
