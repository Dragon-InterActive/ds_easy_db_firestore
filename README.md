# DS-EasyDB Firestore

Cloud Firestore implementation for [DS-EasyDB](https://pub.dev/packages/ds_easy_db) (<https://github.com/Dragon-InterActive/ds_easy_db>). Provides a cloud-hosted NoSQL database with offline support and real-time synchronization.

## Features

- **Cloud-Hosted**: Data stored in Google Cloud with automatic replication
- **Offline Support**: Built-in offline persistence and synchronization
- **Real-Time Updates**: Live data synchronization across devices (use with streams)
- **Scalable**: Automatically scales to meet demand
- **Secure**: Built-in security rules and authentication integration
- **Cross-Platform**: Works on iOS, Android, Web, macOS, Windows

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  ds_easy_db: ^1.0.0
  ds_easy_db_firestore: ^1.0.0
  firebase_core: ^4.2.1  # Required for Firebase initialization
```

## Firebase Setup

### 1. Create Firebase Project

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Create a new project or select existing one
3. Add your Flutter app to the project

### 2. Install Firebase CLI

```bash
npm install -g firebase-tools
dart pub global activate flutterfire_cli
```

### 3. Configure Firebase

```bash
# Login to Firebase
firebase login

# Configure FlutterFire
flutterfire configure
```

This creates `firebase_options.dart` with your Firebase configuration.

### 4. Initialize Firebase

In your `main.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:ds_easy_db/ds_easy_db.dart';
import 'ds_easy_db_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Configure DS-EasyDB
  db.configure(
    storage: DS-EasyDBConfig.storage,
    // ... other configurations
  );
  
  // Firebase is automatically initialized when db.init() is called
  await db.init();
  
  runApp(MyApp());
}
```

**Alternative:** Manual Firebase initialization (if you need it before DS-EasyDB):

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Manual Firebase initialization
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  
  // Configure DS-EasyDB (options parameter not needed now)
  db.configure(
    storage: FirestoreDatabase(), // No options needed
    // ... other configurations
  );
  
  await db.init();
  
  runApp(MyApp());
}
```

### Configuration File

In your `ds_easy_db_config.dart`:

```dart
import 'package:ds_easy_db/ds_easy_db.dart';
import 'package:ds_easy_db_firestore/ds_easy_db_firestore.dart';
import 'firebase_options.dart'; // Your generated Firebase config

class DS-EasyDBConfig {
  static DatabaseRepository get storage => FirestoreDatabase(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  // ... other configurations
}
```

**Note:** The `FirebaseOptions` parameter is optional. If you've already initialized Firebase in your `main.dart`, you can omit it:

## Examples

### Store User Data

```dart
// Create user document
await db.storage.set('users', 'user123', {
  'name': 'John Doe',
  'email': 'john@example.com',
  'age': 30,
  'createdAt': DatabaseRepository.serverTS, // Uses FieldValue.serverTimestamp()
});

// Read user
final user = await db.storage.get('users', 'user123');
print('User: ${user?['name']}');

// Update user
await db.storage.update('users', 'user123', {
  'age': 31,
  'updatedAt': DatabaseRepository.serverTS,
});
```

### Query Data

```dart
// Store posts
await db.storage.set('posts', 'post1', {
  'title': 'Hello World',
  'author': 'user123',
  'published': true,
});

await db.storage.set('posts', 'post2', {
  'title': 'Flutter Tips',
  'author': 'user123',
  'published': false,
});

// Query published posts
final publishedPosts = await db.storage.query('posts',
  where: {'published': true}
);
print('Published posts: ${publishedPosts.length}');

// Check if user has posts
final hasPosts = await db.storage.existsWhere('posts',
  where: {'author': 'user123'}
);
```

### Nested Collections

```dart
// Store user preferences in subcollection
await db.storage.set('users/user123/preferences', 'theme', {
  'mode': 'dark',
  'primaryColor': '#FF5722',
});

// Store user orders
await db.storage.set('users/user123/orders', 'order1', {
  'items': ['item1', 'item2'],
  'total': 99.99,
  'status': 'pending',
  'createdAt': DatabaseRepository.serverTS,
});
```

### Batch Operations

```dart
// Get all users
final allUsers = await db.storage.getAll('users');
print('Total users: ${allUsers?.length}');

// Delete user
await db.storage.delete('users', 'user123');

// Check existence
if (await db.storage.exists('users', 'user123')) {
  print('User exists');
}
```

### E-Commerce Example

```dart
// Create product
await db.storage.set('products', 'prod123', {
  'name': 'Flutter Book',
  'price': 29.99,
  'stock': 100,
  'category': 'books',
  'tags': ['flutter', 'programming'],
});

// Query products by category
final books = await db.storage.query('products',
  where: {'category': 'books'}
);

// Update stock after purchase
await db.storage.update('products', 'prod123', {
  'stock': 99,
  'lastSold': DatabaseRepository.serverTS,
});
```

## Offline Support

Firestore automatically caches data for offline use:

```dart
// This works offline if data was previously loaded
final user = await db.storage.get('users', 'user123');

// Writes are queued and synchronized when online
await db.storage.update('users', 'user123', {
  'lastSeen': DatabaseRepository.serverTS,
});
```

## Real-Time Updates

For real-time updates, use Firestore's native snapshots:

```dart
FirebaseFirestore.instance
  .collection('users')
  .doc('user123')
  .snapshots()
  .listen((snapshot) {
    if (snapshot.exists) {
      print('User updated: ${snapshot.data()}');
    }
  });
```

Or use `ds_easy_db_firebase_realtime` for full real-time support through DS-EasyDB.

## Security Rules

Configure Firestore security rules in Firebase Console:

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Allow authenticated users to read/write their own data
    match /users/{userId} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }
    
    // Public read, authenticated write
    match /posts/{postId} {
      allow read: if true;
      allow write: if request.auth != null;
    }
  }
}
```

## Performance Tips

1. **Index Your Queries**: Create indexes in Firebase Console for complex queries
2. **Batch Reads**: Use `getAll()` instead of multiple `get()` calls
3. **Limit Results**: Add `.limit()` to Firestore queries for large collections
4. **Use Subcollections**: Organize data hierarchically for better performance
5. **Enable Offline Persistence**: Reduces reads and improves offline experience

## Data Modeling

### Good Practices

```dart
// ✅ Flat structure for simple queries
await db.storage.set('users', 'user123', {
  'name': 'John',
  'email': 'john@example.com',
});

// ✅ Arrays for small lists
await db.storage.set('users', 'user123', {
  'favoriteColors': ['red', 'blue', 'green'],
});

// ✅ Maps for grouped data
await db.storage.set('users', 'user123', {
  'address': {
    'street': '123 Main St',
    'city': 'New York',
  },
});
```

### Avoid

```dart
// ❌ Don't use arrays as database
// ❌ Don't deeply nest data (>2 levels)
// ❌ Don't store large binary data (use Firebase Storage)
```

## Limitations

- **Document Size**: Maximum 1MB per document
- **Write Rate**: 1 write per second per document
- **Query Complexity**: Limited to AND queries (use multiple queries for OR)
- **Array Queries**: Limited array querying capabilities
- **Transactions**: Not supported in this wrapper (use Firestore directly)

## When to Use

### ✅ Perfect for Firestore

- User profiles and settings
- Social media posts and comments
- Real-time chat messages
- Product catalogs
- Order tracking
- Analytics events
- Collaborative documents

### ❌ Consider Alternatives

- Large files (use Firebase Storage)
- Complex relational data (use SQL)
- High-frequency writes (>1/sec per doc)
- Simple local storage (use `prefs` or `secure`)
- Real-time only (use `ds_easy_db_firebase_realtime`)

## Pricing

Firestore offers a generous free tier:

- **Reads**: 50,000/day
- **Writes**: 20,000/day
- **Deletes**: 20,000/day
- **Storage**: 1GB

See [Firestore Pricing](https://firebase.google.com/docs/firestore/quotas) for details.

## Troubleshooting

### Firebase Not Initialized

```dart
// Error: Firebase has not been initialized
// Solution: Call Firebase.initializeApp() before db.init()
await Firebase.initializeApp(
  options: DefaultFirebaseOptions.currentPlatform,
);
```

### Permission Denied

```
// Error: PERMISSION_DENIED
// Solution: Update Firestore security rules in Firebase Console
```

### Slow Queries

```dart
// Create composite indexes in Firebase Console for:
await db.storage.query('posts',
  where: {
    'author': 'user123',
    'published': true,
  }
);
```

## License

BSD-3-Clause License - see LICENSE file for details.

Copyright (c) 2025, MasterNemo (Dragon Software)

---

Feel free to clone and extend. It's free to use and share.
