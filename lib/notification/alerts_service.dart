// lib/notification/alerts_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:aquaculture/notification/notification_service.dart';

class AlertsService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Internal helper: add alert + send notification + mark notified
  Future<DocumentReference<Map<String, dynamic>>> _addAndNotify({
    required String uid,
    required String deviceId,
    required Map<String, dynamic> data,
  }) async {
    final ref = _firestore
        .collection('users')
        .doc(uid)
        .collection('alerts')
        .doc(deviceId)
        .collection('logs');

    // Ensure defaults
    data['notified'] = data['notified'] ?? false;
    data['timestamp'] = data['timestamp'] ?? FieldValue.serverTimestamp();
    data['sensor'] = data['sensor'] ?? '';
    data['value'] = data['value'];

    final docRef = await ref.add(data);

    // 🔔 Trigger local notification if title/message present
    final title = (data['title'] as String?)?.trim() ?? '';
    final message = (data['message'] as String?)?.trim() ?? '';

    if (title.isNotEmpty || message.isNotEmpty) {
      final notiService = NotiService();
      await notiService.showNotification(title: title, body: message);

      await docRef.set({'notified': true}, SetOptions(merge: true));
    }

    return docRef;
  }

  /// Save a new alert (used by threshold checks).
  static Future<void> saveAlertToFirestore(
    String deviceId,
    String title,
    String message,
    String sensor,
    num value,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final service = AlertsService();
    await service._addAndNotify(
      uid: user.uid,
      deviceId: deviceId,
      data: {
        'title': title,
        'message': message,
        'sensor': sensor,
        'value': value,
      },
    );
  }

  /// Generic method to add alert with any map data.
  Future<DocumentReference<Map<String, dynamic>>> addAlert(
    String uid,
    String deviceId,
    Map<String, dynamic> data,
  ) {
    return _addAndNotify(uid: uid, deviceId: deviceId, data: data);
  }

  /// Get alerts as a stream for live UI updates.
  Stream<QuerySnapshot<Map<String, dynamic>>> alertsStream(
    String uid,
    String deviceId,
  ) {
    return _firestore
        .collection('users')
        .doc(uid)
        .collection('alerts')
        .doc(deviceId)
        .collection('logs')
        .orderBy('timestamp', descending: true)
        .snapshots();
  }

  /// Delete a single alert.
  Future<void> deleteAlert(
    String uid,
    String deviceId,
    String alertId,
  ) async {
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('alerts')
        .doc(deviceId)
        .collection('logs')
        .doc(alertId)
        .delete();
  }

  /// Clear all alerts for a device.
  Future<void> clearAlerts(String uid, String deviceId) async {
    final snap = await _firestore
        .collection('users')
        .doc(uid)
        .collection('alerts')
        .doc(deviceId)
        .collection('logs')
        .get();

    for (final d in snap.docs) {
      await d.reference.delete();
    }
  }
}
