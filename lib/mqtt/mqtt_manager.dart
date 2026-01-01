// lib/mqtt/mqtt_manager.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:aquaculture/mqtt/state/mqtt_app_state.dart';

class MQTTManager {
  final String broker;
  final int port;
  final String clientIdentifier;
  final String username;
  final String password;
  final MQTTAppState state;

  final String deviceId;
  final String stateName;
  final String district;
  final String area;
  final String site;

  late final MqttServerClient _client;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updatesSub;

  bool _isManuallyDisconnected = false;
  int _reconnectAttempt = 0;

  MQTTManager({
    required this.broker,
    required this.port,
    required this.clientIdentifier,
    required this.username,
    required this.password,
    required this.state,
    required this.deviceId,
    required this.stateName,
    required this.district,
    required this.area,
    required this.site,
  });

  String get topicPath => "aquaculture/$stateName/$district/$area/$site";

  Future<bool> initializeMQTTClient() async {
    _client = MqttServerClient.withPort(broker, clientIdentifier, port)
      ..secure = true
      ..keepAlivePeriod = 35
      ..onConnected = _onConnected
      ..onDisconnected = _onDisconnected
      ..onSubscribed = _onSubscribed
      ..setProtocolV311();
  
    _client.onBadCertificate = (Object certificate) {
      if (certificate is X509Certificate) {
        debugPrint("⚠ Bypassing bad certificate: ${certificate.subject}");
      } else {
        debugPrint("⚠ Unknown certificate type: $certificate");
      }
      return true;
    };
  
    _listenToUpdatesStream();
    return true;
  }
  
  Future<void> connect() async {
    _isManuallyDisconnected = false;
    state.setAppConnectionState(MQTTAppConnectionState.connecting);
  
    _client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientIdentifier)
        .authenticateAs(username, password)
        .startClean();
  
    _client.logging(on: true);
  
    try {
      debugPrint("🔌 Attempting MQTT connection to $broker:$port ...");
      await _client.connect().timeout(const Duration(seconds: 30));
    } catch (e, st) {
      debugPrint("❌ MQTT connection error: $e");
      debugPrint("$st");
      _client.disconnect();
      state.setAppConnectionState(MQTTAppConnectionState.disconnected);
      _scheduleReconnect();
      return;
    }
  
    final status = _client.connectionStatus;
    if (status?.state == MqttConnectionState.connected) {
      debugPrint("✅ MQTT connected successfully");
      _subscribeToTopic();
      _reconnectAttempt = 0;
    } else {
      debugPrint("❌ MQTT connection failed: ${status?.returnCode}");
      _client.disconnect();
      state.setAppConnectionState(MQTTAppConnectionState.disconnected);
      _scheduleReconnect();
    }
  }

  void disconnect() {
    _isManuallyDisconnected = true;
    _updatesSub?.cancel();
    _updatesSub = null;
    try {
      if (_client.connectionStatus?.state == MqttConnectionState.connected) {
        _client.unsubscribe(topicPath);
      }
    } catch (_) {}
    _client.disconnect();
    debugPrint("🔌 Disconnected MQTT for device $deviceId");
  }

  final Set<String> _subscribedTopics = {};

  void _subscribeToTopic() {
    if (_subscribedTopics.contains(topicPath)) {
      debugPrint("⚠ Already subscribed to $topicPath");
      return;
    }
    try {
      _client.subscribe(topicPath, MqttQos.atMostOnce);
      _subscribedTopics.add(topicPath);
      debugPrint("📡 Subscribed to $topicPath");
    } catch (e) {
      debugPrint("❌ Failed to subscribe to $topicPath: $e");
    }
  }

  void _listenToUpdatesStream() {
    _updatesSub?.cancel();
    _updatesSub = _client.updates?.listen((messages) {
      if (messages.isEmpty) return;
      final rec = messages.first;
      final msg = rec.payload;
      if (msg is! MqttPublishMessage) return;

      final payload =
          MqttPublishPayload.bytesToStringAsString(msg.payload.message);
      final topic = rec.topic;
      _handleIncomingMessage(topic, payload);
    }, onError: (e) {
      debugPrint("❌ MQTT updates stream error: $e");
    });
  }

  Future<void> _handleIncomingMessage(String topic, String payload) async {
    if (topic != topicPath) return;
  
    Map<String, dynamic> raw;
    try {
      raw = jsonDecode(payload) as Map<String, dynamic>;
    } catch (e) {
      debugPrint("❌ Invalid JSON payload for $deviceId: $payload");
      return;
    }
  
    final normalizedSensors = <String, double>{};
    final statusUpdates = <String, String>{};
  
    for (final entry in raw.entries) {
      final key = entry.key.toLowerCase();
      final val = entry.value;
      final numVal = _toDouble(val);
  
      if (numVal != null) {
        normalizedSensors[key] = numVal;
        state.updateSensorData(deviceId, key, numVal);
      } else if (val is String) {
        statusUpdates[key] = val;
        state.updateStatus(deviceId, key, val);
      }
    }
  
    if (normalizedSensors.isEmpty && statusUpdates.isEmpty) return;
  
    final timestamp = FieldValue.serverTimestamp();
  
    // 1. Write Latest Readings
    try {
      await _firestore.collection("latest_readings").doc(deviceId).set({
        ...normalizedSensors,
        ...statusUpdates, 
        "timestamp": timestamp,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint("❌ Write latest_readings failed: $e");
    }
  
    // 2. Write History
    if (normalizedSensors.isNotEmpty) {
      try {
        await _firestore.collection("readings").doc(deviceId).collection("data").add({
          ...normalizedSensors,
          "timestamp": timestamp,
        });
      } catch (e) {
        debugPrint("❌ Write readings history failed: $e");
      }
    }
    
    // ❌ DELETED: Threshold checks logic removed from here.
  }

  void _onConnected() {
    _reconnectAttempt = 0;
    state.setAppConnectionState(MQTTAppConnectionState.connected);
  }

  void _onDisconnected() {
    state.setAppConnectionState(MQTTAppConnectionState.disconnected);
    _updatesSub?.cancel();
    _updatesSub = null;
    if (!_isManuallyDisconnected) _scheduleReconnect();
  }

  void _onSubscribed(String topic) {
    debugPrint("✅ Subscribed to $topic");
  }

  void _scheduleReconnect() {
    _reconnectAttempt = (_reconnectAttempt + 1).clamp(1, 10);
    final delay = Duration(seconds: (5 * _reconnectAttempt).clamp(5, 60));
    debugPrint("🔄 Reconnecting in ${delay.inSeconds} seconds...");
    Future.delayed(delay, () {
      if (!_isManuallyDisconnected) connect();
    });
  }

  static double? _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  void publish(String subtopic, String message, {bool retain = false}) {
    if (_client.connectionStatus?.state != MqttConnectionState.connected) {
      debugPrint("❌ Cannot publish: MQTT not connected");
      return;
    }
    final pubTopic = "$topicPath/$subtopic";
    final builder = MqttClientPayloadBuilder();
    builder.addString(message);
    try {
      _client.publishMessage(pubTopic, MqttQos.atLeastOnce, builder.payload!, retain: retain);
      debugPrint("📤 Published to $pubTopic: $message (Retain: $retain)");
    } catch (e) {
      debugPrint("❌ Failed to publish: $e");
    }
  }
}