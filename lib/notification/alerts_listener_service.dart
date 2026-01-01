// lib/notification/alerts_listener_service.dart
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
  final Duration _staleDataThreshold = const Duration(minutes: 5); 

  void startListening() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      final deviceSnap = await _firestore
          .collection('devices')
          .where('members', arrayContains: user.uid)
          .get();

      if (deviceSnap.docs.isEmpty) {
        debugPrint("⚠️ AlertListener: No devices found for user.");
      }

      for (final doc in deviceSnap.docs) {
        final deviceId = doc.id;
        debugPrint("✅ AlertListener: Monitoring $deviceId");
        _listenToDeviceReadings(user.uid, deviceId);
      }
    } catch (e) {
      debugPrint("❌ AlertListener Error: $e");
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
      if (!_isDataFresh(newData['timestamp'])) return;

      final thresholdDoc = await _firestore
          .collection('users')
          .doc(uid)
          .collection('thresholds')
          .doc(deviceId)
          .get();
  
      if (!thresholdDoc.exists) return;
  
      final thresholds = thresholdDoc.data()!;
      
      final violations = <String>[];       
      final violatedSensors = <String>[];
  
      final sensors = ['ph', 'temperature', 'tds', 'turbidity', 'waterlevel'];
  
      for (final sensor in sensors) {
        if (!thresholds.containsKey(sensor)) continue;
        
        final tData = thresholds[sensor];
        if (tData == null || tData is! Map) continue;

        final min = _toDoubleSafe(tData['min']);
        final max = _toDoubleSafe(tData['max']);
        final value = _toDoubleSafe(newData[sensor]);

        if (value == null || min == null || max == null) continue;

        if (value < min || value > max) {
           violations.add('$sensor: ${value.toStringAsFixed(2)} (Range: $min-$max)');
           violatedSensors.add(sensor);
        }
      }
  
      if (violations.isNotEmpty) {
        final now = DateTime.now();
        final lastAlertTime = _lastAlertTime[deviceId];
        final alertStateChanged = _isInAlertState[deviceId] != true;
  
        if ((lastAlertTime == null ||
                now.difference(lastAlertTime) > _cooldown) ||
            alertStateChanged) {
          
          // --- Title Logic: Specific vs Group ---
          String title;
          String sensorKey;

          if (violatedSensors.length == 1) {
            title = "${violatedSensors.first.toUpperCase()} Alert"; 
            sensorKey = violatedSensors.first;
          } else {
            title = "Threshold Alert";
            sensorKey = "multiple";
          }
          
          final alertMessage = violations.join(', ');
  
          await AlertsService().addAlert(
            uid,
            deviceId,
            {
              'title': title,
              'message': 'Readings out of range: $alertMessage',
              'sensor': sensorKey,
              'value': null, 
              'readings': newData,
            },
          );
  
          _lastAlertTime[deviceId] = now;
          _isInAlertState[deviceId] = true;
          debugPrint("🚨 $title Triggered: $alertMessage");
        }
      } else {
        _isInAlertState[deviceId] = false;
      }
    });
  
    _subscriptions.add(sub);
  }

  bool _isDataFresh(dynamic timestamp) {
    if (timestamp == null) return true;
    DateTime dataTime;
    if (timestamp is Timestamp) {
      dataTime = timestamp.toDate();
    } else if (timestamp is int) {
      dataTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
    } else {
      return true;
    }
    final diff = DateTime.now().difference(dataTime);
    return diff.abs() < _staleDataThreshold;
  }

  double? _toDoubleSafe(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  void stopListening() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
  }

  void dispose() => stopListening();
}