# DSEasyDB Firestore Example

```dart
import 'package:ds_easy_db/ds_easy_db.dart';
import 'package:ds_easy_db_firestore/ds_easy_db_firestore.dart';
import 'firebase_options.dart';

void main() async {
  // Configure with Firestore
  db.configure(
    prefs: MockDatabase(),
    secure: MockDatabase(),
    storage: FirestoreDatabase(
      options: DefaultFirebaseOptions.currentPlatform,
    ),
    stream: MockDatabase(),
  );
  
  await db.init();
  
  // Create user document
  await db.storage.set('users', 'user123', {
    'name': 'John Doe',
    'email': 'john@example.com',
    'age': 30,
    'createdAt': DatabaseRepository.serverTS,
  });
  
  // Read user
  final user = await db.storage.get('users', 'user123');
  print('User: ${user?['name']}');
  
  // Query published posts
  final posts = await db.storage.query('posts',
    where: {'published': true}
  );
  print('Published posts: ${posts.length}');
  
  // Update user
  await db.storage.update('users', 'user123', {
    'age': 31,
    'updatedAt': DatabaseRepository.serverTS,
  });
}
```
