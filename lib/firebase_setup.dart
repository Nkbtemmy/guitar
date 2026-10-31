import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Starts Firebase, which usage stats, crash reports and accounts all go through. False when this
/// build isn't connected to a Firebase project (see README): they all quietly stay off then.
Future<bool> startFirebase({FirebaseOptions? options}) async {
  try {
    await Firebase.initializeApp(options: options);
    return true;
  } catch (e) {
    debugPrint('Firebase did not start ($e)');
    return false;
  }
}
