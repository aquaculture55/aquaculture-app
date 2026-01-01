// lib/pages/home_page.dart
import 'package:aquaculture/pages/devicepickerpage.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import '../device_context.dart';
import 'sensorcard.dart';
import 'threshold_settings_page.dart';
import 'package:aquaculture/mqtt/state/mqtt_app_state.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<String> _sensorKeys = [
    "temperature",
    "ph",
    "tds",
    "turbidity",
    "waterlevel"
  ];
  
  Map<String, dynamic> _cachedReadings = {};

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final deviceCtx = Provider.of<DeviceContext>(context);
    final device = deviceCtx.selected;
    final mqttState = context.watch<MQTTAppState>();

    if (user == null) return const Center(child: Text("Please log in"));
    if (device == null) return _noDeviceSelectedWidget();

    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance
          .collection('devices')
          .doc(device.deviceId)
          .get(),
      builder: (context, deviceSnap) {
        final meta = deviceSnap.data?.data() ?? device.meta;

        return Column(
          children: [
            _deviceInfoBar(device, meta, mqttState),
            Expanded(
              child: _buildReadingsAndThresholds(user.uid, device.deviceId),
            ),
          ],
        );
      },
    );
  }

  Widget _deviceInfoBar(DeviceInfo device, Map<String, dynamic> meta,
          MQTTAppState mqttState) =>
      Material(
        color: Colors.blue.shade50,
        child: InkWell(
          onTap: _showDevicePicker,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.devices_other, color: Colors.blue),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(device.displayTopic,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14)),
                      Text(_formatLocation(meta),
                          style: const TextStyle(
                              fontSize: 12, color: Colors.black54)),
                    ],
                  ),
                ),
                Icon(
                  mqttState.appConnectionState ==
                          MQTTAppConnectionState.connected
                      ? Icons.cloud_done
                      : Icons.cloud_off,
                  color: mqttState.appConnectionState ==
                          MQTTAppConnectionState.connected
                      ? Colors.green
                      : Colors.red,
                ),
                const SizedBox(width: 6),
                const Icon(Icons.arrow_drop_down, color: Colors.blue),
              ],
            ),
          ),
        ),
      );

  String _formatLocation(Map<String, dynamic> meta) {
    final site = meta['site'] ?? 'Unknown Site';
    final area = meta['area'] ?? '';
    final district = meta['district'] ?? '';
    final state = meta['state'] ?? '';
    return [site, area, district, state].where((e) => e.isNotEmpty).join(' — ');
  }

  Future<void> _showDevicePicker() async {
    final selectedDevice = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DevicePickerPage()),
    );

    if (selectedDevice != null && selectedDevice is DeviceInfo) {
      final deviceCtx = Provider.of<DeviceContext>(context, listen: false);
      deviceCtx.setSelected(selectedDevice);
      _cachedReadings.clear();
      setState(() {}); 
    }
  }

  Widget _buildReadingsAndThresholds(String userId, String deviceId) {
    final thresholdsStream = FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('thresholds')
        .doc(deviceId)
        .snapshots();

    final readingsStream = FirebaseFirestore.instance
        .collection('latest_readings')
        .doc(deviceId)
        .snapshots();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: thresholdsStream,
      builder: (context, thresholdSnap) {
        if (thresholdSnap.hasError) {
          return _errorBox("Failed to load thresholds", thresholdSnap.error);
        }

        Map<String, Map<String, double>> thresholds = {};
        if (thresholdSnap.hasData && thresholdSnap.data!.exists) {
          thresholds = _parseThresholds(thresholdSnap.data);
        }

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: readingsStream,
          builder: (context, readingsSnap) {
            Map<String, dynamic> readings = _cachedReadings;
            if (readingsSnap.hasData && readingsSnap.data!.exists) {
              readings = _parseReadings(readingsSnap.data);
              _cachedReadings = readings;
              // ❌ NO ALERT LOGIC HERE
            }

            if (readingsSnap.hasError) {
              return Column(
                children: [
                  _errorBanner("Failed to load readings", readingsSnap.error),
                  Expanded(
                      child: _buildSensorList(thresholds, _cachedReadings)),
                ],
              );
            }

            if (thresholds.isEmpty) {
              return _thresholdWarningWidget();
            }

            return _buildSensorList(thresholds, readings);
          },
        );
      },
    );
  }

  Map<String, Map<String, double>> _parseThresholds(
      DocumentSnapshot<Map<String, dynamic>>? doc) {
    final Map<String, Map<String, double>> thresholds = {};
    if (doc == null || !doc.exists) return thresholds;
    final tData = doc.data() ?? {};
    for (final key in _sensorKeys) {
      final s = tData[key];
      if (s is Map<String, dynamic>) {
        thresholds[key] = {
          'min': _toDoubleSafe(s['min']),
          'max': _toDoubleSafe(s['max']),
        };
      }
    }
    return thresholds;
  }

  Map<String, dynamic> _parseReadings(
      DocumentSnapshot<Map<String, dynamic>>? doc) {
    if (doc == null || !doc.exists) return {};
    return Map<String, dynamic>.from(doc.data() ?? {});
  }

  static double _toDoubleSafe(dynamic value) {
    if (value == null) return double.nan;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? double.nan;
    return double.nan;
  }

  Widget _noDeviceSelectedWidget() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.info_outline, size: 56),
              const SizedBox(height: 12),
              const Text('No device selected. Tap the device icon to choose.'),
              const SizedBox(height: 12),
              ElevatedButton(
                  onPressed: _showDevicePicker,
                  child: const Text("Choose Device")),
            ],
          ),
        ),
      );

  Widget _thresholdWarningWidget() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning, color: Colors.orange, size: 60),
              const SizedBox(height: 12),
              const Text(
                "Thresholds are not set!\nPlease configure thresholds in settings.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: const Icon(Icons.settings),
                label: const Text("Go to Settings"),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const ThresholdSettingsPage()),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _errorBox(String title, Object? error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 60),
              const SizedBox(height: 12),
              Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text("$error",
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey)),
                ),
            ],
          ),
        ),
      );

  Widget _errorBanner(String title, Object? error) => Material(
        color: Colors.red.withOpacity(0.08),
        child: ListTile(
          leading: const Icon(Icons.error_outline, color: Colors.red),
          title: Text(title),
          subtitle: error != null ? Text("$error") : null,
        ),
      );

  Widget _buildSensorList(Map<String, Map<String, double>> thresholds,
      Map<String, dynamic> readings) {
    final media = MediaQuery.of(context);
    final isPortrait = media.orientation == Orientation.portrait;
    final hasData = readings.isNotEmpty;

    if (isPortrait) {
      return Column(
        children: [
          Expanded(
            child: Column(
              children: _sensorKeys.map((key) {
                return Expanded(
                  child: SensorCard(
                    sensor: SensorData(
                      key: key,
                      icon: _sensorIcon(key),
                      unit: _sensorUnit(key),
                      value: _toDoubleSafe(readings[key]),
                    ),
                    thresholds: thresholds[key],
                    scale: 1.1,
                  ),
                );
              }).toList(),
            ),
          ),
          _footerWidget(hasData, readings),
        ],
      );
    } else {
      return Column(
        children: [
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(6),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                childAspectRatio: 1.5,
              ),
              itemCount: _sensorKeys.length,
              itemBuilder: (_, i) {
                final key = _sensorKeys[i];
                return SensorCard(
                  sensor: SensorData(
                    key: key,
                    icon: _sensorIcon(key),
                    unit: _sensorUnit(key),
                    value: _toDoubleSafe(readings[key]),
                  ),
                  thresholds: thresholds[key],
                  scale: 1.2,
                );
              },
            ),
          ),
          _footerWidget(hasData, readings),
        ],
      );
    }
  }

  Widget _footerWidget(bool hasData, Map<String, dynamic> readings) => Padding(
        padding: const EdgeInsets.all(6.0),
        child: Text(
          hasData
              ? 'Last updated: ${_formatTimestamp(readings['timestamp'])}'
              : 'No recent data available',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade600,
            fontStyle: hasData ? FontStyle.normal : FontStyle.italic,
          ),
        ),
      );

  static IconData _sensorIcon(String key) {
    switch (key) {
      case "temperature": return Icons.thermostat;
      case "ph": return Icons.water;
      case "tds": return Icons.bubble_chart;
      case "turbidity": return Icons.opacity;
      case "waterlevel": return Icons.waves;
      default: return Icons.device_unknown;
    }
  }

  static String _sensorUnit(String key) {
    switch (key) {
      case "temperature": return "°C";
      case "ph": return "";
      case "tds": return "ppm";
      case "turbidity": return "Level";
      case "waterlevel": return "%";
      default: return "";
    }
  }

  static String _formatTimestamp(dynamic ts) {
    try {
      if (ts is Timestamp) return ts.toDate().toLocal().toString().substring(0, 16);
      if (ts is DateTime) return ts.toLocal().toString().substring(0, 16);
      if (ts is int) return DateTime.fromMillisecondsSinceEpoch(ts).toLocal().toString().substring(0, 16);
    } catch (_) {}
    return '--';
  }
}