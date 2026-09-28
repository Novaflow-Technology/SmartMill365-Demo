import 'package:firebase_core/firebase_core.dart';

bool isFirebaseInitialized = false;

Future<void> initFirebase() async {
  if (!isFirebaseInitialized) {
    try {
      await Firebase.initializeApp(
        // SmartMill's own Firebase project (smartmill365-demo) — this was
        // still pointing at intechsf365-607a9, an unrelated SmartFactory
        // project, meaning every login and every direct Firestore/RTDB read
        // was hitting the wrong project's data. No Realtime Database exists
        // for smartmill365-demo yet, so databaseURL is left unset until one
        // is provisioned — device_settings' RTDB writes need that first.
        options: const FirebaseOptions(
          apiKey: "AIzaSyAyCoBo8417nLxoB2QY2PSUi6ZrJ__YlnA",
          authDomain: "smartmill365-demo.firebaseapp.com",
          projectId: "smartmill365-demo",
          storageBucket: "smartmill365-demo.firebasestorage.app",
          messagingSenderId: "1070797963738",
          appId: "1:1070797963738:web:c853294036769373cf80e3",
          measurementId: "G-3T60H4KSEC",
        ),
      );
      isFirebaseInitialized = true;
    } catch (e) {
      print('Error initializing Firebase: $e');
    }
  }
}
