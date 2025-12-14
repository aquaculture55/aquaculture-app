import 'dart:async'; // Required for Timer
import 'dart:convert';
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
  // 15 Minutes = 900 Seconds
  static const int kSleepDurationSeconds = 15 * 60; 

  // Store the time of the last command
  DateTime? _lastFeederCommandTime;
  DateTime? _lastLampCommandTime;

  // Timer to update the UI countdown every second
  Timer? _uiRefreshTimer;

  @override
  bool get wantKeepAlive => true; // Keep page alive so timer keeps running

  @override
  void initState() {
    super.initState();
    // Start a timer to refresh the UI every second (for the countdown text)
    _uiRefreshTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        // Only rebuild if we are actually cooling down to save resources
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

  // Helper to format remaining seconds into "MM:SS" (e.g., 14:59)
  String _formatCountdown(int totalSeconds) {
    final int minutes = totalSeconds ~/ 60;
    final int seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required by AutomaticKeepAliveClientMixin

    final mqttState = context.watch<MQTTAppState>();
    final deviceCtx = Provider.of<DeviceContext>(context);
    final device = deviceCtx.selected;

    if (device == null) return const Center(child: Text("No device selected"));

    // ================= LOGIC: FISH FEEDER =================
    final String feederStatus = mqttState.getSensorValue(device.deviceId, 'feeder');
    final DateTime? lastFeederUpdate = mqttState.getLastUpdateTime(device.deviceId, 'feeder');

    // 1. Check Network Sync (Waiting for reply)
    bool isFeederSyncing = false;
    if (_lastFeederCommandTime != null) {
      if (lastFeederUpdate == null || lastFeederUpdate.isBefore(_lastFeederCommandTime!)) {
        isFeederSyncing = true;
      }
    }

    // 2. Check Safety Timer (15 Minutes Sleep Mode)
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


    // ================= LOGIC: 12V LAMP =================
    final String lampStatus = mqttState.getSensorValue(device.deviceId, 'lamp');
    final bool isLampOn = lampStatus.toUpperCase() == "ON";
    final DateTime? lastLampUpdate = mqttState.getLastUpdateTime(device.deviceId, 'lamp');

    // 1. Check Network Sync
    bool isLampSyncing = false;
    if (_lastLampCommandTime != null) {
      if (lastLampUpdate == null || lastLampUpdate.isBefore(_lastLampCommandTime!)) {
        isLampSyncing = true;
      }
    }

    // 2. Check Safety Timer
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
              // ================= FISH FEEDER CARD =================
              _buildControlCard(
                context,
                title: "Fish Feeder",
                icon: Icons.set_meal,
                iconColor: Colors.orange,
                statusText: feederStatus,
                statusColor: Colors.deepOrange,
                isDisabled: isFeederDisabled,
                // Logic: Show "Syncing" first, then "Sleep Mode MM:SS"
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

              // ================= 12V LAMP CARD =================
              _buildControlCard(
                context,
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
  }

  // Reusable Widget Builder
  Widget _buildControlCard(
    BuildContext context, {
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
            
            // Status Chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: statusColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: statusColor.withOpacity(0.5)),
              ),
              child: Text(
                "Status: $statusText",
                style: TextStyle(fontWeight: FontWeight.bold, color: statusColor),
              ),
            ),
            
            const SizedBox(height: 20),
            
            // Action Button
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