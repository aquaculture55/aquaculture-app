import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../device_context.dart';
import '../notification/alerts_service.dart';

class FirebaseMsgService {
  final FirebaseMessaging _fm = FirebaseMessaging.instance;
  final DeviceContext deviceContext;

  FirebaseMsgService({required this.deviceContext});

  /// Initialize FCM
  Future<void> init() async {
    // Request permission
    final settings = await _fm.requestPermission();
    debugPrint('🔔 FCM permission: ${settings.authorizationStatus}');

    // Get token
    final token = await _fm.getToken();
    if (token != null) await _saveToken(token);

    // Token refresh
    _fm.onTokenRefresh.listen(_saveToken);

    // Foreground messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // Opened from notification
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpened);

    // If app was killed
    final initialMessage = await _fm.getInitialMessage();
    if (initialMessage != null) {
      _handleMessageOpened(initialMessage);
    }
  }

  /// Foreground notifications
  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    try {
      final notif = message.notification;
      final data = message.data;
      if (notif == null) return;

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      // Resolve deviceId
      final deviceId =
          data['deviceId'] ?? deviceContext.selected?.deviceId ?? 'general';

      // Save alert via AlertsService
      await AlertsService().addAlert(
        user.uid,
        deviceId,
        {
          'title': notif.title ?? 'Notification',
          'message': notif.body ?? '',
          'sensor': data['sensor'] ?? '',
          'value': _parseValue(data['value']),
        },
      );
    } catch (e, st) {
      debugPrint("❌ Error handling foreground message: $e\n$st");
    }
  }

  void _handleMessageOpened(RemoteMessage message) {
    debugPrint("📲 Notification tapped: ${message.messageId}");
    // TODO: Navigate to AlertsPage or DeviceDetailPage
  }

  /// Save FCM token
  Future<void> _saveToken(String token) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final deviceId = deviceContext.selected?.deviceId ?? 'general';

      final ref = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('fcmTokens')
          .doc(deviceId);

      await ref.set({
        'email': user.email,
        'fcmTokens': FieldValue.arrayUnion([token]),
        'lastUpdated': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      debugPrint("✅ FCM token saved for device: $deviceId");
    } catch (e) {
      debugPrint("❌ Failed to save FCM token: $e");
    }
  }

  /// Subscribe to device topic
  Future<void> subscribeToDeviceTopic(DeviceInfo device) async {
    try {
      await _fm.subscribeToTopic(device.fcmTopic);
      await deviceContext.setSelected(device, saveToken: true);
      debugPrint("📡 Subscribed to topic: ${device.fcmTopic}");
    } catch (e) {
      debugPrint("❌ Failed to subscribe: $e");
    }
  }

  /// Unsubscribe from device topic
  Future<void> unsubscribeFromDeviceTopic(DeviceInfo device) async {
    try {
      await _fm.unsubscribeFromTopic(device.fcmTopic);
      deviceContext.clear();
      debugPrint("📴 Unsubscribed from topic: ${device.fcmTopic}");
    } catch (e) {
      debugPrint("❌ Failed to unsubscribe: $e");
    }
  }

  /// Parse values safely
  dynamic _parseValue(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? v;
    return v.toString();
  }
}
