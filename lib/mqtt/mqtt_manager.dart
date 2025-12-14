import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:aquaculture/notification/notification_service.dart';
import 'package:aquaculture/mqtt/state/mqtt_app_state.dart';

class MQTTManager {
  final String broker;
  final int port;
  final String clientIdentifier;
  final String username;
  final String password;
  final MQTTAppState state;

  /// Firestore/device metadata
  final String deviceId;
  final String stateName;
  final String district;
  final String area;
  final String site;

  late final MqttServerClient _client;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final NotiService _notiService = NotiService();

  /// device thresholds (min/max per sensor)
  Map<String, Map<String, double>> _thresholds = {};

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _thresholdSub;
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

  /// aquaculture/<state>/<district>/<area>/<site>
  String get topicPath => "aquaculture/$stateName/$district/$area/$site";

  // ------------------------------------------------------------
  // Init
  // ------------------------------------------------------------
  Future<bool> initializeMQTTClient() async {
    _client = MqttServerClient.withPort(broker, clientIdentifier, port)
      ..secure = true
      ..keepAlivePeriod = 35
      ..onConnected = _onConnected
      ..onDisconnected = _onDisconnected
      ..onSubscribed = _onSubscribed
      ..setProtocolV311();
  
    // Bypass SSL certificate safely (cast to X509Certificate)
    _client.onBadCertificate = (Object certificate) {
      if (certificate is X509Certificate) {
        debugPrint("⚠ Bypassing bad certificate: ${certificate.subject}");
      } else {
        debugPrint("⚠ Unknown certificate type: $certificate");
      }
      return true;
    };
  
    _listenForThresholdUpdates();
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
    debugPrint(
        "📡 MQTT connection status: ${status?.state}, return code: ${status?.returnCode}");
  
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

    _thresholdSub?.cancel();
    _thresholdSub = null;

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

  // ------------------------------------------------------------
  // Subscriptions / Listeners
  // ------------------------------------------------------------
  // Maintain a local set to track topics we've subscribed to
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

  void _listenForThresholdUpdates() {
    _thresholdSub?.cancel();
    final user = _auth.currentUser;
    if (user == null) return;

    _thresholdSub = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('thresholds')
        .doc(deviceId)
        .snapshots()
        .listen((doc) {
      if (!doc.exists) {
        _thresholds = {};
        state.updateThresholds(deviceId, _thresholds);
        return;
      }

      final data = doc.data() ?? {};
      final next = <String, Map<String, double>>{};
      for (final entry in data.entries) {
        final v = entry.value;
        if (v is Map &&
            v.containsKey('min') &&
            v.containsKey('max')) {
          final min = _toDouble(v['min']);
          final max = _toDouble(v['max']);
          if (min != null && max != null) {
            next[entry.key.toLowerCase()] = {'min': min, 'max': max};
          }
        }
      }
      _thresholds = next;
      state.updateThresholds(deviceId, _thresholds);
    }, onError: (e) {
      debugPrint("❌ Threshold listener error: $e");
    });
  }

  // ------------------------------------------------------------
  // Incoming messages
  // ------------------------------------------------------------
  Future<void> _handleIncomingMessage(String topic, String payload) async {
    // Only handle messages from our subscribed topic
    if (topic != topicPath) return;

    Map<String, dynamic> raw;
    try {
      raw = jsonDecode(payload) as Map<String, dynamic>;
    } catch (e) {
      debugPrint("❌ Invalid JSON payload for $deviceId: $payload");
      return;
    }

    final normalized = <String, double>{};
    for (final entry in raw.entries) {
      final sensorKey = entry.key.toLowerCase();
      final numVal = _toDouble(entry.value);
      if (numVal != null) {
        normalized[sensorKey] = numVal;
        state.updateSensorData(deviceId, sensorKey, numVal);
      }
    }

    if (normalized.isEmpty) return;

    // Firestore writes
    final timestamp = FieldValue.serverTimestamp();

    try {
      await _firestore
          .collection("latest_readings")
          .doc(deviceId)
          .set({
        ...normalized,
        "timestamp": timestamp,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint("❌ Write latest_readings failed: $e");
    }

    try {
      await _firestore
          .collection("readings")
          .doc(deviceId)
          .collection("data")
          .add({
        ...normalized,
        "timestamp": timestamp,
      });
    } catch (e) {
      debugPrint("❌ Write readings history failed: $e");
    }

    // Threshold checks & notifications
    final user = _auth.currentUser;
    if (user == null) return;

    for (final entry in _thresholds.entries) {
      final sensorKey = entry.key;
      final th = entry.value;
      final min = th['min'];
      final max = th['max'];
      final currentValue = normalized[sensorKey];

      if (currentValue == null || min == null || max == null) continue;

      if (currentValue < min || currentValue > max) {
        final isLow = currentValue < min;
        final title = "⚠ ${sensorKey.toUpperCase()} ${isLow ? 'Low' : 'High'}";
        final msg = isLow
            ? "${currentValue.toStringAsFixed(2)} below min ($min)"
            : "${currentValue.toStringAsFixed(2)} above max ($max)";

        try {
          await _firestore
              .collection("users")
              .doc(user.uid)
              .collection("alerts")
              .doc(deviceId)
              .collection("logs")
              .add({
            "title": title,
            "message": msg,
            "sensor": sensorKey,
            "value": currentValue,
            "timestamp": timestamp,
          });
        } catch (e) {
          debugPrint("❌ Failed to write alert: $e");
        }

        try {
          await _notiService.showNotification(title: title, body: msg);
        } catch (e) {
          debugPrint("❌ Local notification error: $e");
        }
      }
    }
  }

  // ------------------------------------------------------------
  // MQTT callbacks
  // ------------------------------------------------------------
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

  // ------------------------------------------------------------
  // Reconnect backoff
  // ------------------------------------------------------------
  void _scheduleReconnect() {
    _reconnectAttempt = (_reconnectAttempt + 1).clamp(1, 10);
    final delay = Duration(seconds: (5 * _reconnectAttempt).clamp(5, 60));
    debugPrint("🔄 Reconnecting in ${delay.inSeconds} seconds...");
    Future.delayed(delay, () {
      if (!_isManuallyDisconnected) connect();
    });
  }

  // ------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------
  static double? _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// Publishes a control command to the device topic.

  /// [subtopic] example: "control" -> topic becomes ".../site/control"
  /// [message] example: "{"pump": "ON"}"

  void publish(String subtopic, String message, {bool retain = true}) {
    if (_client.connectionStatus?.state != MqttConnectionState.connected) {
      debugPrint("❌ Cannot publish: MQTT not connected");
      return;
    }

    final pubTopic = "$topicPath/$subtopic";
    final builder = MqttClientPayloadBuilder();
    builder.addString(message);

    try {
      _client.publishMessage(
        pubTopic,
        MqttQos.atLeastOnce,
        builder.payload!,
        retain: retain,
      );
      debugPrint("📤 Published to $pubTopic: $message (Retain: $retain)");
    } catch (e) {
      debugPrint("❌ Failed to publish: $e");
    }
  }
}
