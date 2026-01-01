import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../device_context.dart';
import '../mqtt/state/mqtt_app_state.dart';
import 'control_controller.dart';

class ControlPage extends StatefulWidget {
  const ControlPage({super.key});

  @override
  State<ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends State<ControlPage>
    with AutomaticKeepAliveClientMixin {
  final ControlController _controller = ControlController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Initialize controller with device ID once available
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final deviceCtx = Provider.of<DeviceContext>(context, listen: false);
      if (deviceCtx.selected != null) {
        _controller.init(deviceCtx.selected!.deviceId);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // Helper to parse Firestore timestamp safely
  DateTime? _parseTimestamp(dynamic val) {
    if (val == null) return null;
    if (val is Timestamp) return val.toDate();
    if (val is String) return DateTime.tryParse(val);
    if (val is int) return DateTime.fromMillisecondsSinceEpoch(val);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final mqttState = context.watch<MQTTAppState>();
    final deviceCtx = Provider.of<DeviceContext>(context);
    final device = deviceCtx.selected;

    if (device == null) return const Center(child: Text("No device selected"));

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('latest_readings')
          .doc(device.deviceId)
          .snapshots(),
      builder: (context, snapshot) {
        // ---------------------------------------------
        // 1. DATA GATHERING
        // ---------------------------------------------
        // Note: For Feeder, we now rely on the controller for the label ("FED"/"READY")
        // but we still fetch lamp status ("ON"/"OFF") from DB/MQTT.
        String lampStatus = mqttState.getSensorValue(device.deviceId, 'lamp');

        DateTime? fsFeederTime;
        DateTime? fsLampTime;

        if (snapshot.hasData && snapshot.data!.exists) {
          final data = snapshot.data!.data() as Map<String, dynamic>?;
          if (data != null) {
            // Fill missing lamp status from DB
            if (data.containsKey('lamp') && lampStatus == "N/A") {
              lampStatus = data['lamp'].toString();
            }
            // Extract timestamps
            fsFeederTime = _parseTimestamp(data['feeder_last_updated']);
            fsLampTime = _parseTimestamp(data['lamp_last_updated']);
          }
        }

        // ---------------------------------------------
        // 2. SYNC WITH CONTROLLER
        // ---------------------------------------------

        // Determine newest Feeder time (MQTT vs Firestore)
        final mqttFeederTime = mqttState.getLastUpdateTime(
          device.deviceId,
          'feeder',
        );
        DateTime? newestFeeder = mqttFeederTime;
        if (fsFeederTime != null) {
          if (newestFeeder == null || fsFeederTime.isAfter(newestFeeder)) {
            newestFeeder = fsFeederTime;
          }
        }
        _controller.syncFeederTime(device.deviceId, newestFeeder);

        // Determine newest Lamp time
        final mqttLampTime = mqttState.getLastUpdateTime(
          device.deviceId,
          'lamp',
        );
        DateTime? newestLamp = mqttLampTime;
        if (fsLampTime != null) {
          if (newestLamp == null || fsLampTime.isAfter(newestLamp)) {
            newestLamp = fsLampTime;
          }
        }
        _controller.syncLampTime(device.deviceId, newestLamp);

        // ---------------------------------------------
        // 3. UI RENDERING
        // ---------------------------------------------

        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            // --- Feeder Status Logic (Controlled by App) ---
            final bool showGreenStatus = _controller.isRecentlyFed;
            final String feederDisplayStatus =
                _controller.feederStatusLabel; // "FED" or "READY"
            final Color feederColor = showGreenStatus
                ? Colors.green
                : Colors.deepOrange;

            // --- Lamp Status Logic (Controlled by Device State) ---
            final bool isLampOn = lampStatus.toUpperCase() == "ON";
            final Color lampColor = isLampOn
                ? Colors.green[700]!
                : Colors.red[700]!;

            final bool isFeederDisabled =
                _controller.isFeederSyncing || _controller.isFeederCooling;
            final bool isLampDisabled =
                _controller.isLampSyncing || _controller.isLampCooling;

            if (_controller.uiMessage != null) {
              final String msg = _controller.uiMessage!;

              // 1. Clear the message immediately so it doesn't popup twice
              _controller.clearMessage();

              // 2. Show the SnackBar safely after the build is done
              WidgetsBinding.instance.addPostFrameCallback((_) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(msg),
                    backgroundColor: Colors.red,
                    duration: const Duration(seconds: 2),
                  ),
                );
              });
            }

            return Scaffold(
              appBar: AppBar(title: const Text("Control Terminal")),
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(18.0),
                  child: Column(
                    children: [
                      // FEEDER CARD
                      _buildControlCard(
                        context: context,
                        title: "Fish Feeder",
                        icon: Icons.set_meal,
                        iconColor: showGreenStatus
                            ? Colors.green
                            : Colors.orange,
                        statusText: feederDisplayStatus,
                        statusColor: feederColor,
                        lastUpdatedText: _controller.feederLastUpdatedText,
                        isDisabled: isFeederDisabled,
                        buttonText: _controller.feederButtonText,
                        onPressed: () {
                          final payload = jsonEncode({"feeder": "ACTIVATE"});
                          mqttState.sendControlCommand(
                            device.deviceId,
                            payload,
                          );
                          _controller.handleFeederPress(device.deviceId);
                        },
                      ),
                      const SizedBox(height: 15),

                      // LAMP CARD
                      _buildControlCard(
                        context: context,
                        title: "Lamp",
                        icon: Icons.lightbulb,
                        iconColor: isLampOn ? Colors.yellow[700]! : Colors.grey,
                        statusText: lampStatus,
                        statusColor: lampColor,
                        lastUpdatedText: _controller.lampLastUpdatedText,
                        isDisabled: isLampDisabled,
                        buttonText: _controller.getLampButtonText(isLampOn),
                        onPressed: () {
                          final String command = isLampOn ? "OFF" : "ON";
                          final payload = jsonEncode({"lamp": command});
                          mqttState.sendControlCommand(
                            device.deviceId,
                            payload,
                          );
                          _controller.handleLampPress(device.deviceId);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildControlCard({
    required BuildContext context,
    required String title,
    required IconData icon,
    required Color iconColor,
    required String statusText,
    required Color statusColor,
    required String lastUpdatedText,
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
                color: statusColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: statusColor.withOpacity(0.5)),
              ),
              child: Text(
                "Status: $statusText",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: statusColor,
                ),
              ),
            ),

            const SizedBox(height: 8),
            Text(
              lastUpdatedText,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
                fontStyle: FontStyle.italic,
              ),
            ),

            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  backgroundColor: isDisabled
                      ? Colors.grey[300]
                      : Colors.blueGrey,
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
