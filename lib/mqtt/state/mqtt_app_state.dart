import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:aquaculture/mqtt/mqtt_manager.dart';

enum MQTTAppConnectionState { connected, disconnected, connecting }

class MQTTAppState with ChangeNotifier {
  MQTTAppConnectionState _appConnectionState =
      MQTTAppConnectionState.disconnected;

  /// deviceId -> sensor -> value (string for formatted display)
  final Map<String, Map<String, String>> _sensorData = {};

  /// (deviceId-sensor) -> list of {time, value}
  final Map<String, List<Map<String, dynamic>>> _sensorHistory = {};

  /// deviceId -> sensor -> {min,max}
  final Map<String, Map<String, Map<String, double>>> _thresholds = {};

  /// Active MQTT managers by device
  final Map<String, MQTTManager> _managers = {};

  // ---------------------------
  // Connection State
  // ---------------------------
  MQTTAppConnectionState get appConnectionState => _appConnectionState;

  void setAppConnectionState(MQTTAppConnectionState state) {
    if (_appConnectionState == state) return;
    _appConnectionState = state;
    notifyListeners();
  }

  // ---------------------------
  // Sensor Data Management
  // ---------------------------
  void updateSensorData(String deviceId, String sensorKey, double value) {
    _sensorData.putIfAbsent(deviceId, () => {});
    _sensorData[deviceId]![sensorKey] = value.toStringAsFixed(2);

    final historyKey = "$deviceId-$sensorKey";
    _sensorHistory.putIfAbsent(historyKey, () => []);

    final list = _sensorHistory[historyKey]!;
    list.add({"time": DateTime.now(), "value": value});

    _trimHistory(list);

    notifyListeners();
  }

  void updateThresholds(
    String deviceId,
    Map<String, Map<String, double>> newThresholds,
  ) {
    _thresholds[deviceId] = newThresholds;
    notifyListeners();
  }

  String getSensorValue(String deviceId, String sensorName) {
    return _sensorData[deviceId]?[sensorName] ?? "N/A";
  }

  List<Map<String, dynamic>> getHistoryFor(
    String deviceId,
    String sensorName,
  ) {
    return _sensorHistory["$deviceId-$sensorName"] ?? [];
  }

  void clearHistory(String deviceId) {
    _sensorHistory.removeWhere((key, _) => key.startsWith(deviceId));
    _sensorData.remove(deviceId);
    notifyListeners();
  }

  void _trimHistory(List<Map<String, dynamic>> list, {int maxLength = 500}) {
    if (list.length > maxLength) {
      list.removeRange(0, list.length - maxLength);
    }
  }

  // ---------------------------
  // MQTT Connection Management
  // ---------------------------
  Future<void> connect(User user, String deviceId) async {
    // Disconnect previous manager for this device
    disconnect(deviceId);

    try {
      // Fetch device metadata
      final deviceDoc = await FirebaseFirestore.instance
          .collection("devices")
          .doc(deviceId)
          .get();

      if (!deviceDoc.exists) {
        debugPrint("❌ Device $deviceId not found in Firestore");
        return;
      }

      final data = deviceDoc.data() ?? {};
      final stateName = (data["state"] as String?) ?? "unknown_state";
      final district = (data["district"] as String?) ?? "unknown_district";
      final area = (data["area"] as String?) ?? "unknown_area";
      final site = (data["site"] as String?) ?? deviceId; // fallback

      final clientId =
          'flutter_${user.uid.substring(0, 8)}_${DateTime.now().millisecondsSinceEpoch % 100000}';

      final manager = MQTTManager(
        broker: 'j05f0669.ala.asia-southeast1.emqxsl.com',
        port: 8883,
        clientIdentifier: clientId,
        username: 'datacake',
        password: 'iiotsme',
        state: this,
        deviceId: deviceId,
        stateName: stateName,
        district: district,
        area: area,
        site: site,
      );

      _managers[deviceId] = manager;

      final ok = await manager.initializeMQTTClient();
      if (ok) {
        await manager.connect();
        debugPrint("✅ Connected to $deviceId via MQTT");
      } else {
        debugPrint("❌ MQTT initialization failed for $deviceId");
      }
    } catch (e, st) {
      debugPrint("❌ Error connecting to $deviceId: $e");
      debugPrintStack(stackTrace: st);
    }
  }

  void disconnect(String deviceId) {
    final manager = _managers.remove(deviceId);
    if (manager != null) {
      manager.disconnect();
      debugPrint("🔌 Disconnected device $deviceId");
    }
  }

  void disconnectAll() {
    for (final entry in _managers.entries) {
      entry.value.disconnect();
      debugPrint("🔌 Disconnected device ${entry.key}");
    }
    _managers.clear();
  }

  void sendControlCommand(String deviceId, String command) {
    final manager = _managers[deviceId];
    if (manager != null) {
      // Publishes to 'aquaculture/.../site/control'
      manager.publish("control", command, retain: true); 
    } else {
      debugPrint("❌ No active MQTT manager for device $deviceId");
    }
  }

  void updateStatus(String deviceId, String key, String value) {
    _sensorData.putIfAbsent(deviceId, () => {});
    _sensorData[deviceId]![key] = value; // Store string directly
    notifyListeners();
  }

  
}
