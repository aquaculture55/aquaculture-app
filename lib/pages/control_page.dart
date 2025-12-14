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

class _ControlPageState extends State<ControlPage> {
  // We store the time we sent the command.
  // We only re-enable the button if the MQTT update is NEWER than this time.
  DateTime? _lastFeederCommandTime;
  DateTime? _lastLampCommandTime;

  @override
  Widget build(BuildContext context) {
    final mqttState = context.watch<MQTTAppState>();
    final deviceCtx = Provider.of<DeviceContext>(context);
    final device = deviceCtx.selected;

    if (device == null) return const Center(child: Text("No device selected"));

    // ---------------------------------------------------------------
    // 1. Calculate LAMP State
    // ---------------------------------------------------------------
    final String currentLampStatus = mqttState.getSensorValue(device.deviceId, 'lamp');
    final bool isLampOn = currentLampStatus == "ON";
    final DateTime? lastLampUpdate = mqttState.getLastUpdateTime(device.deviceId, 'lamp');

    // Button is disabled if:
    // We sent a command AND (We haven't received an update OR the update is older than our command)
    bool isLampDisabled = false;
    if (_lastLampCommandTime != null) {
      if (lastLampUpdate == null || lastLampUpdate.isBefore(_lastLampCommandTime!)) {
        isLampDisabled = true;
      }
    }

    // ---------------------------------------------------------------
    // 2. Calculate FEEDER State
    // ---------------------------------------------------------------
    final DateTime? lastFeederUpdate = mqttState.getLastUpdateTime(device.deviceId, 'feeder');
    
    bool isFeederDisabled = false;
    if (_lastFeederCommandTime != null) {
      // If we commanded it, wait until we get a newer message from the device
      if (lastFeederUpdate == null || lastFeederUpdate.isBefore(_lastFeederCommandTime!)) {
        isFeederDisabled = true;
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text("Control Terminal")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // ================= FISH FEEDER CONTROL =================
            const Icon(Icons.set_meal, size: 80, color: Colors.orange),
            const SizedBox(height: 10),
            Text("Fish Feeder", style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
              ),
              onPressed: isFeederDisabled
                  ? null // Disabled while waiting for device
                  : () {
                      // 1. Send Command
                      final payload = jsonEncode({"feeder": "ACTIVATE"});
                      mqttState.sendControlCommand(device.deviceId, payload);

                      // 2. Mark the time. Button disables immediately.
                      // It will ONLY re-enable when device sends a status update with a newer time.
                      setState(() {
                        _lastFeederCommandTime = DateTime.now();
                      });
                    },
              child: Text(
                isFeederDisabled ? "Waiting for Device..." : "Feed Now",
                style: const TextStyle(fontSize: 18),
              ),
            ),

            const Divider(height: 60, thickness: 2),

            // ================= 12V LAMP CONTROL =================
            Icon(Icons.lightbulb,
                size: 80,
                color: isLampOn ? Colors.yellow[700] : Colors.grey),
            const SizedBox(height: 10),
            Text("12V Lamp", style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                backgroundColor: Colors.blueGrey,
                foregroundColor: Colors.white,
              ),
              onPressed: isLampDisabled
                  ? null
                  : () {
                      final String command = isLampOn ? "OFF" : "ON";
                      final payload = jsonEncode({"lamp": command});
                      mqttState.sendControlCommand(device.deviceId, payload);

                      setState(() {
                        _lastLampCommandTime = DateTime.now();
                      });
                    },
              child: Text(
                isLampDisabled
                    ? "Syncing..."
                    : "Turn ${isLampOn ? 'OFF' : 'ON'}",
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}