import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart'; // Required for StreamBuilder
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../device_context.dart';
import '../mqtt/state/mqtt_app_state.dart';

class ControlPage extends StatefulWidget {
  const ControlPage({super.key});

  @override
  State<ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends State<ControlPage> with AutomaticKeepAliveClientMixin {
  // --- CONFIGURATION ---
  static const int kSleepDurationSeconds = 15 * 60; // 15 Minutes

  DateTime? _lastFeederCommandTime;
  DateTime? _lastLampCommandTime;
  Timer? _uiRefreshTimer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _uiRefreshTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        if (_lastFeederCommandTime != null || _lastLampCommandTime != null) {
           setState(() {});
        }
      }
    });
  }

  @override
  void dispose() {
    _uiRefreshTimer?.cancel();
    super.dispose();
  }

  String _formatCountdown(int totalSeconds) {
    final int minutes = totalSeconds ~/ 60;
    final int seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final mqttState = context.watch<MQTTAppState>();
    final deviceCtx = Provider.of<DeviceContext>(context);
    final device = deviceCtx.selected;

    if (device == null) return const Center(child: Text("No device selected"));

    // Listen to Firestore Real-time to keep multi-user synced
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('latest_readings')
          .doc(device.deviceId)
          .snapshots(),
      builder: (context, snapshot) {
        
        String feederStatus = mqttState.getSensorValue(device.deviceId, 'feeder');
        String lampStatus = mqttState.getSensorValue(device.deviceId, 'lamp');

        // Prefer Firestore data if available (Sync source)
        if (snapshot.hasData && snapshot.data!.exists) {
          final data = snapshot.data!.data() as Map<String, dynamic>?;
          if (data != null) {
            if (data.containsKey('feeder')) {
               final fsVal = data['feeder'].toString();
               if (feederStatus == "N/A" || fsVal.isNotEmpty) feederStatus = fsVal;
            }
            if (data.containsKey('lamp')) {
               final lsVal = data['lamp'].toString();
               if (lampStatus == "N/A" || lsVal.isNotEmpty) lampStatus = lsVal;
            }
          }
        }

        final bool isLampOn = lampStatus.toUpperCase() == "ON";
        final DateTime? lastFeederUpdate = mqttState.getLastUpdateTime(device.deviceId, 'feeder');
        final DateTime? lastLampUpdate = mqttState.getLastUpdateTime(device.deviceId, 'lamp');

        // --- Logic: Fish Feeder ---
        bool isFeederSyncing = false;
        if (_lastFeederCommandTime != null) {
          if (lastFeederUpdate == null || lastFeederUpdate.isBefore(_lastFeederCommandTime!)) {
            isFeederSyncing = true;
          }
        }

        bool isFeederCooling = false;
        int feederRemaining = 0;
        if (_lastFeederCommandTime != null) {
          final secondsSince = DateTime.now().difference(_lastFeederCommandTime!).inSeconds;
          if (secondsSince < kSleepDurationSeconds) {
            isFeederCooling = true;
            feederRemaining = kSleepDurationSeconds - secondsSince;
          }
        }
        final bool isFeederDisabled = isFeederSyncing || isFeederCooling;

        // --- Logic: 12V Lamp ---
        bool isLampSyncing = false;
        if (_lastLampCommandTime != null) {
          if (lastLampUpdate == null || lastLampUpdate.isBefore(_lastLampCommandTime!)) {
            isLampSyncing = true;
          }
        }

        bool isLampCooling = false;
        int lampRemaining = 0;
        if (_lastLampCommandTime != null) {
          final secondsSince = DateTime.now().difference(_lastLampCommandTime!).inSeconds;
          if (secondsSince < kSleepDurationSeconds) {
            isLampCooling = true;
            lampRemaining = kSleepDurationSeconds - secondsSince;
          }
        }
        final bool isLampDisabled = isLampSyncing || isLampCooling;

        return Scaffold(
          appBar: AppBar(title: const Text("Control Terminal")),
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  _buildControlCard(
                    context: context, // FIX: Added named parameter 'context:'
                    title: "Fish Feeder",
                    icon: Icons.set_meal,
                    iconColor: Colors.orange,
                    statusText: feederStatus,
                    statusColor: Colors.deepOrange,
                    isDisabled: isFeederDisabled,
                    buttonText: isFeederSyncing
                        ? "Waiting for Device..."
                        : (isFeederCooling ? "Sleep Mode ${_formatCountdown(feederRemaining)}" : "Feed Now"),
                    onPressed: () {
                      final payload = jsonEncode({"feeder": "ACTIVATE"});
                      mqttState.sendControlCommand(device.deviceId, payload);
                      setState(() {
                        _lastFeederCommandTime = DateTime.now();
                      });
                    },
                  ),
                  const SizedBox(height: 20),
                  _buildControlCard(
                    context: context, // FIX: Added named parameter 'context:'
                    title: "12V Lamp",
                    icon: Icons.lightbulb,
                    iconColor: isLampOn ? Colors.yellow[700]! : Colors.grey,
                    statusText: lampStatus,
                    statusColor: isLampOn ? Colors.green[700]! : Colors.red[700]!,
                    isDisabled: isLampDisabled,
                    buttonText: isLampSyncing
                        ? "Syncing..."
                        : (isLampCooling ? "Sleep Mode ${_formatCountdown(lampRemaining)}" : "Turn ${isLampOn ? 'OFF' : 'ON'}"),
                    onPressed: () {
                      final String command = isLampOn ? "OFF" : "ON";
                      final payload = jsonEncode({"lamp": command});
                      mqttState.sendControlCommand(device.deviceId, payload);
                      setState(() {
                        _lastLampCommandTime = DateTime.now();
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // Helper widget with fixed named parameters
  Widget _buildControlCard({
    required BuildContext context,
    required String title,
    required IconData icon,
    required Color iconColor,
    required String statusText,
    required Color statusColor,
    required bool isDisabled,
    required String buttonText,
    required VoidCallback onPressed,
  }) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            Icon(icon, size: 60, color: iconColor),
            const SizedBox(height: 10),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                // FIX: Replaced deprecated .withOpacity with .withValues(alpha:)
                color: statusColor.withValues(alpha: 0.1), 
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: statusColor.withValues(alpha: 0.5)),
              ),
              child: Text(
                "Status: $statusText",
                style: TextStyle(fontWeight: FontWeight.bold, color: statusColor),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  backgroundColor: isDisabled ? Colors.grey[300] : Colors.blueGrey,
                  foregroundColor: isDisabled ? Colors.grey[600] : Colors.white,
                ),
                onPressed: isDisabled ? null : onPressed,
                child: Text(buttonText, style: const TextStyle(fontSize: 18)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}