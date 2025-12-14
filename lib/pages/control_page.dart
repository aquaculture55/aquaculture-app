import 'dart:async';
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
  // --- Fish Feeder State ---
  bool _feederDisabled = false;
  int _feederCooldown = 0;
  Timer? _feederTimer;

  // --- 12V Lamp State ---
  bool _lampDisabled = false;
  int _lampCooldown = 0;
  Timer? _lampTimer;

  @override
  void dispose() {
    _feederTimer?.cancel();
    _lampTimer?.cancel();
    super.dispose();
  }

  void _startCooldown(String deviceType, int durationSeconds) {
    setState(() {
      if (deviceType == 'feeder') {
        _feederDisabled = true;
        _feederCooldown = durationSeconds;
      } else {
        _lampDisabled = true;
        _lampCooldown = durationSeconds;
      }
    });

    Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        if (deviceType == 'feeder') {
          if (_feederCooldown > 0) {
            _feederCooldown--;
          } else {
            _feederDisabled = false;
            timer.cancel();
          }
        } else {
          if (_lampCooldown > 0) {
            _lampCooldown--;
          } else {
            _lampDisabled = false;
            timer.cancel();
          }
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final mqttState = context.watch<MQTTAppState>();
    final deviceCtx = Provider.of<DeviceContext>(context);
    final device = deviceCtx.selected;

    if (device == null) return const Center(child: Text("No device selected"));

    // --- FIX: Get the current status from MQTT State ---
    // This reads the value stored in your app state (e.g., "ON", "OFF", or "N/A")
    final String currentLampStatus = mqttState.getSensorValue(device.deviceId, 'lamp');
    final bool isLampOn = currentLampStatus == "ON";

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
              onPressed: _feederDisabled
                  ? null
                  : () {
                      final payload = jsonEncode({"feeder": "ACTIVATE"});
                      mqttState.sendControlCommand(device.deviceId, payload);
                      _startCooldown('feeder', 30);
                    },
              child: Text(
                _feederDisabled ? "Wait ${_feederCooldown}s" : "Feed Now",
                style: const TextStyle(fontSize: 18),
              ),
            ),

            const Divider(height: 60, thickness: 2),

            // ================= 12V LAMP CONTROL =================
            // Bonus: I updated the icon color to reflect the actual status!
            Icon(Icons.lightbulb, 
              size: 80, 
              color: isLampOn ? Colors.yellow[700] : Colors.grey
            ),
            const SizedBox(height: 10),
            Text("12V Lamp", style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                backgroundColor: Colors.blueGrey,
                foregroundColor: Colors.white,
              ),
              onPressed: _lampDisabled
                  ? null
                  : () {
                      // --- FIX: Use the calculated variable here ---
                      final String command = isLampOn ? "OFF" : "ON";
                      final payload = jsonEncode({"lamp": command});
                      
                      mqttState.sendControlCommand(device.deviceId, payload);
                      
                      _startCooldown('lamp', 5);
                    },
              child: Text(
                _lampDisabled 
                    ? "Cooling down ${_lampCooldown}s" 
                    : "Turn ${isLampOn ? 'OFF' : 'ON'}", // Text changes dynamically
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}