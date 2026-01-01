// lib/mqtt/mqtt_manager.dart
import 'dart:async';
import 'dart:convert';
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

  StreamSubscription? _updatesSub;

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

  String get topicPath =>
      "aquaculture/${stateName.toLowerCase()}/${district.toLowerCase()}/${area.toLowerCase()}/${site.toLowerCase()}";

  Future<bool> initializeMQTTClient() async {
    _client = MqttServerClient.withPort(broker, clientIdentifier, port)
      ..secure = true
      ..keepAlivePeriod = 35
      ..onConnected = _onConnected
      ..onDisconnected = _onDisconnected
      ..onSubscribed = _onSubscribed
      ..setProtocolV311();

    _client.logging(on: true);

    _client.onBadCertificate = (Object certificate) {
      debugPrint("⚠ Bypassing bad certificate");
      return true;
    };

    // FIXED: Do NOT listen here. We listen in connect() to ensure fresh subscription.
    return true;
  }

  Future<void> connect() async {
    _isManuallyDisconnected = false;
    
    // 1. Setup Listener BEFORE connecting
    _listenToUpdatesStream();
    
    state.setAppConnectionState(MQTTAppConnectionState.connecting);

    _client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientIdentifier)
        .authenticateAs(username, password)
        .startClean();

    try {
      debugPrint("🔌 Attempting MQTT connection to $broker:$port ...");
      await _client.connect().timeout(const Duration(seconds: 30));
    } catch (e) {
      debugPrint("❌ MQTT connection error: $e");
      _client.disconnect();
      state.setAppConnectionState(MQTTAppConnectionState.disconnected);
      _scheduleReconnect();
      return;
    }

    if (_client.connectionStatus?.state == MqttConnectionState.connected) {
      debugPrint("✅ MQTT connected successfully");
      _subscribeToTopic();
      _reconnectAttempt = 0;
    } else {
      debugPrint("❌ MQTT connection failed");
      _client.disconnect();
      state.setAppConnectionState(MQTTAppConnectionState.disconnected);
      _scheduleReconnect();
    }
  }

  void disconnect() {
    _isManuallyDisconnected = true;
    _updatesSub?.cancel();
    _updatesSub = null;
    _client.disconnect();
    debugPrint("🔌 Disconnected MQTT for device $deviceId");
  }

  void _subscribeToTopic() {
    try {
      _client.subscribe(topicPath, MqttQos.atMostOnce);
      debugPrint("📡 Subscribed to $topicPath");
    } catch (e) {
      debugPrint("❌ Failed to subscribe to $topicPath: $e");
    }
  }

  // --- FIXED LISTENER LOGIC ---
  void _listenToUpdatesStream() {
    _updatesSub?.cancel();
    
    // Check if updates stream is available
    if (_client.updates == null) {
      debugPrint("❌ Error: _client.updates stream is NULL");
      return;
    }

    _updatesSub = _client.updates!.listen(
      (List<MqttReceivedMessage<MqttMessage?>>? c) {
        // 1. Log that an event occurred
        debugPrint("🔔 MQTT STREAM EVENT RECEIVED");

        if (c == null || c.isEmpty) return;

        final recMess = c[0];
        final topic = recMess.topic;
        final msg = recMess.payload;

        // 2. Validate Message Type
        if (msg is! MqttPublishMessage) {
          debugPrint("ℹ️ Ignored non-publish message type: ${msg.runtimeType}");
          return;
        }

        // 3. Extract Payload safely
        try {
          final payload = MqttPublishPayload.bytesToStringAsString(
            msg.payload.message,
          );
          _handleIncomingMessage(topic, payload);
        } catch (e) {
          debugPrint("❌ Error parsing payload bytes: $e");
        }
      },
      onError: (e) {
        debugPrint("❌ MQTT updates stream error: $e");
      },
    );
  }

  Future<void> _handleIncomingMessage(String topic, String payload) async {
    debugPrint("📥 MQTT RX: Topic='$topic' Payload='$payload'");

    // Loose check for topic match (ignoring case)
    if (!topic.toLowerCase().contains(topicPath.toLowerCase())) {
       debugPrint("⚠ Note: Topic '$topic' might not match '$topicPath'");
    }

    Map<String, dynamic> raw;
    try {
      raw = jsonDecode(payload) as Map<String, dynamic>;
    } catch (e) {
      debugPrint("❌ Invalid JSON payload: $payload");
      return;
    }

    final normalizedSensors = <String, double>{};
    final statusUpdates = <String, String>{};

    for (final entry in raw.entries) {
      final key = entry.key.toLowerCase();
      final val = entry.value;
      
      // Try to parse as double (for sensors like 'temp', 'ph')
      final numVal = _toDouble(val);

      if (numVal != null) {
        normalizedSensors[key] = numVal;
        state.updateSensorData(deviceId, key, numVal);
      } else {
        // Assume String status (e.g. "FED", "ON")
        final strVal = val.toString();
        statusUpdates[key] = strVal;
        
        // This updates the UI immediately
        state.updateStatus(deviceId, key, strVal);
        debugPrint("✅ Status Updated in AppState: $key = $strVal");
      }
    }

    // Write to Firestore (Latest Readings)
    if (normalizedSensors.isNotEmpty || statusUpdates.isNotEmpty) {
      try {
        await _firestore.collection("latest_readings").doc(deviceId).set({
          ...normalizedSensors,
          ...statusUpdates,
          "timestamp": FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint("❌ Firestore write failed: $e");
      }
    }

    // Write History (Only numbers)
    if (normalizedSensors.isNotEmpty) {
      try {
        await _firestore
            .collection("readings")
            .doc(deviceId)
            .collection("data")
            .add({...normalizedSensors, "timestamp": FieldValue.serverTimestamp()});
      } catch (_) {}
    }
  }

  void _onConnected() {
    _reconnectAttempt = 0;
    state.setAppConnectionState(MQTTAppConnectionState.connected);
  }

  void _onDisconnected() {
    state.setAppConnectionState(MQTTAppConnectionState.disconnected);
    if (!_isManuallyDisconnected) _scheduleReconnect();
  }

  void _onSubscribed(String topic) {
    debugPrint("✅ Subscribed callback: $topic");
  }

  void _scheduleReconnect() {
    _reconnectAttempt = (_reconnectAttempt + 1).clamp(1, 10);
    Future.delayed(Duration(seconds: 5 * _reconnectAttempt), () {
      if (!_isManuallyDisconnected) connect();
    });
  }

  static double? _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  void publish(String subtopic, String message, {bool retain = false}) {
    if (_client.connectionStatus?.state != MqttConnectionState.connected) return;
    final pubTopic = "$topicPath/$subtopic";
    final builder = MqttClientPayloadBuilder();
    builder.addString(message);
    _client.publishMessage(pubTopic, MqttQos.atLeastOnce, builder.payload!, retain: retain);
    debugPrint("📤 Published to $pubTopic: $message");
  }
}