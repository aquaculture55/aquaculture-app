import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../notification/alerts_service.dart';

class AlertListenerService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  final List<StreamSubscription> _subscriptions = [];
  final Map<String, DateTime> _lastAlertTime = {};
  final Map<String, bool> _isInAlertState = {};
  final Duration _cooldown = const Duration(minutes: 10);

  void startListening() async {
    final user = _auth.currentUser;
    if (user == null) return;

    final subSnap = await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('subscriptions')
        .get();

    for (final doc in subSnap.docs) {
      final deviceId = doc.id;
      _listenToDeviceReadings(user.uid, deviceId);
    }
  }

  void _listenToDeviceReadings(String uid, String deviceId) {
    final sub = _firestore
        .collection('latest_readings')
        .doc(deviceId)
        .snapshots()
        .listen((snapshot) async {
      if (!snapshot.exists) return;
  
      final newData = snapshot.data()!;
      final thresholdDoc = await _firestore
          .collection('users')
          .doc(uid)
          .collection('thresholds')
          .doc(deviceId)
          .get();
  
      if (!thresholdDoc.exists) return;
  
      final thresholds = thresholdDoc.data()!;
      final alerts = <String>[];
  
      final sensors = ['ph', 'temperature', 'tds', 'turbidity', 'waterlevel'];
  
      for (final sensor in sensors) {
        if (!thresholds.containsKey(sensor)) continue;
  
        final min = thresholds[sensor]['min'];
        final max = thresholds[sensor]['max'];
        final value = newData[sensor];
  
        if (value is num && (value < min || value > max)) {
          alerts.add('$sensor: $value (Range: $min-$max)');
        }
      }
  
      if (alerts.isNotEmpty) {
        final now = DateTime.now();
        final lastAlertTime = _lastAlertTime[deviceId];
        final alertStateChanged = _isInAlertState[deviceId] != true;
  
        if ((lastAlertTime == null ||
                now.difference(lastAlertTime) > _cooldown) ||
            alertStateChanged) {
          final alertMessage = alerts.join(', ');
  
          await AlertsService().addAlert(
            uid,
            deviceId,
            {
              'title': 'Threshold Alert',
              'message': alertMessage,
              'sensor': 'multiple',
              'value': null,
              'readings': newData,
            },
          );
  
          _lastAlertTime[deviceId] = now;
          _isInAlertState[deviceId] = true;
  
          debugPrint("🚨 Threshold alert triggered for $deviceId: $alertMessage");
        }
      } else {
        _isInAlertState[deviceId] = false;
      }
    });
  
    _subscriptions.add(sub);
  }


  void stopListening() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
  }

  void dispose() => stopListening();
}
