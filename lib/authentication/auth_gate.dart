import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:aquaculture/authentication/sign_in_page.dart';
import 'package:aquaculture/pages/main_page.dart';
import 'package:aquaculture/main.dart'; // For alertListener and notiService

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  User? _currentUser;
  late final StreamSubscription<User?> _authSubscription;
  bool _alertListenerActive = false;

  @override
  void initState() {
    super.initState();

    // Listen for auth changes
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null) {
        // Only start the listener if not already active
        if (!_alertListenerActive) {
          alertListener.startListening();
          _alertListenerActive = true;
        }
      } else {
        // Stop listener on logout
        if (_alertListenerActive) {
          alertListener.stopListening();
          _alertListenerActive = false;
        }
      }

      setState(() => _currentUser = user);
    });
  }

  @override
  void dispose() {
    _authSubscription.cancel();
    if (_alertListenerActive) {
      alertListener.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _currentUser == null ? const SignInPage() : const MainPage();
  }
}
