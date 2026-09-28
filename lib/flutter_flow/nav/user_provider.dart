import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

const _apiBase = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';

class UserProvider with ChangeNotifier {
  User? currentUser;
  String? name;
  String? email;
  String? roles;

  UserProvider() {
    FirebaseAuth.instance.authStateChanges().listen((user) {
      currentUser = user;
      if (user != null) {
        fetchUserData();
      } else {
        name = null;
        email = null;
        roles = null;
        notifyListeners();
      }
    });
  }

  Future<void> fetchUserData() async {
    if (currentUser == null) return;
    try {
      final allRes = await http.get(Uri.parse('$_apiBase/users'));
      if (allRes.statusCode != 200) return;

      final List<dynamic> allUsers = json.decode(allRes.body);
      final uid = currentUser!.uid;

      Map<String, dynamic>? match = allUsers.firstWhere(
        (u) => u['UID']?.toString() == uid,
        orElse: () => null,
      );

      if (match == null) {
        final userEmail = currentUser!.email;
        if (userEmail != null) {
          match = allUsers.firstWhere(
            (u) => u['email']?.toString().toLowerCase() == userEmail.toLowerCase(),
            orElse: () => null,
          );
          if (match != null) {
            // Auto-fix UID mismatch
            await http.put(
              Uri.parse('$_apiBase/users/fixUid/${match['id']}'),
              headers: {'Content-Type': 'application/json'},
              body: json.encode({'uid': uid}),
            );
          }
        }
      }

      if (match != null) {
        name = match['name'] as String?;
        email = match['email'] as String?;
        roles = match['roles'] as String?;
        notifyListeners();
      }
    } catch (e) {
      print('Error fetching user data: $e');
    }
  }

  void updateUserRole(String newRole) {
    roles = newRole;
    notifyListeners();
  }
}
