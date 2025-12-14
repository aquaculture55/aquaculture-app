import 'dart:async';
import 'package:aquaculture/device_context.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final DeviceContext deviceContext; // ✅ injected singleton

  AuthService({required this.deviceContext}); // ✅ constructor

  Stream<User?> get user => _auth.authStateChanges();
  StreamSubscription<String>? _tokenRefreshSub;

  // -------------------------------
  // Save user FCM token (only if device selected)
  // -------------------------------
  Future<void> _saveUserData(User user, {String? token}) async {
    try {
      token ??= await _messaging.getToken();
      if (token == null) return;

      if (deviceContext.selected != null) {
        await deviceContext.saveFcmToken(token);
      } else {
        debugPrint("ℹ️ No device selected yet, skipping FCM token save.");
      }
    } catch (e) {
      debugPrint("⚠️ Error saving user data: $e");
    }
  }

  // -------------------------------
  // Listen for FCM token refresh
  // -------------------------------
  void _listenForTokenRefresh(User user) {
    _tokenRefreshSub?.cancel();
    _tokenRefreshSub = _messaging.onTokenRefresh.listen((newToken) async {
      debugPrint("🔄 Token refreshed: $newToken");
      await _saveUserData(user, token: newToken);
    });
  }

  // -------------------------------
  // Initialize notifications (permission + first token)
  // -------------------------------
  Future<void> _initNotifications(User user) async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    debugPrint("🔔 Notification permission: ${settings.authorizationStatus}");

    final token = await _messaging.getToken();
    if (token != null) {
      debugPrint("📲 Current FCM token: $token");
      await _saveUserData(user, token: token);
    }
  }

  // -------------------------------
  // Shared post-login setup
  // -------------------------------
  Future<void> _postLoginSetup(User user) async {
    _listenForTokenRefresh(user);
    await _initNotifications(user);
  }

  // -------------------------------
  // Email + Password Sign In
  // -------------------------------
  Future<bool> signInWithEmailAndPassword(String email, String password) async {
    try {
      final result = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );
      if (result.user != null) {
        await _postLoginSetup(result.user!);
        return true;
      }
      return false;
    } on FirebaseAuthException catch (e) {
      debugPrint('❌ Sign-in error: ${e.message}');
      return false;
    }
  }

  // -------------------------------
  // Email + Password Sign Up
  // -------------------------------
  Future<bool> signUpWithEmailAndPassword(String email, String password) async {
    try {
      final result = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );
      if (result.user != null) {
        await _postLoginSetup(result.user!);
        return true;
      }
      return false;
    } on FirebaseAuthException catch (e) {
      debugPrint('❌ Sign-up error: ${e.message}');
      return false;
    }
  }

  // -------------------------------
  // Password Reset
  // -------------------------------
  Future<bool> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
      return true;
    } on FirebaseAuthException catch (e) {
      debugPrint('❌ Password reset error: ${e.message}');
      return false;
    }
  }

  // -------------------------------
  // Google Sign In
  // -------------------------------
  Future<User?> signInWithGoogle() async {
    try {
      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) return null;

      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final result = await _auth.signInWithCredential(credential);
      if (result.user != null) {
        await _postLoginSetup(result.user!);
      }
      return result.user;
    } on FirebaseAuthException catch (e) {
      debugPrint('❌ Google sign-in error: ${e.message}');
      return null;
    }
  }

  // -------------------------------
  // Sign Out and cleanup
  // -------------------------------
  Future<void> signOut() async {
    try {
      final user = _auth.currentUser;

      if (user != null && deviceContext.selected != null) {
        final token = await _messaging.getToken();
        if (token != null) {
          final tokenDoc = _firestore
              .collection('users')
              .doc(user.uid)
              .collection('fcmTokens')
              .doc(deviceContext.selected!.deviceId);

          await tokenDoc.set({
            'fcmTokens': FieldValue.arrayRemove([token]),
            'lastUpdated': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

          debugPrint("🧹 Removed FCM token for ${deviceContext.selected!.deviceId} on sign out: $token");
        }
      }

      _tokenRefreshSub?.cancel();
      _tokenRefreshSub = null;

      try {
        await _googleSignIn.signOut();
      } catch (_) {
        debugPrint("ℹ️ Not a Google user, skipping Google sign out.");
      }

      await _auth.signOut();
      deviceContext.clear();
    } catch (e) {
      debugPrint("❌ Sign out error: $e");
    }
  }
}
