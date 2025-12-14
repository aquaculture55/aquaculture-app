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

// 1. Add AutomaticKeepAliveClientMixin to prevent reset when switching tabs
class _ControlPageState extends State<ControlPage> with AutomaticKeepAliveClientMixin {
  
  // We store the time we sent the command.
  DateTime? _lastFeederCommandTime;
  DateTime? _lastLampCommandTime;

  // 2. Required by the Mixin to keep page alive in background
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // 3. Must call super.build

    final mqttState = context.watch<MQTTAppState>();
    final deviceCtx = Provider.of<DeviceContext>(context);
    final device = deviceCtx.selected;

    if (device == null) return const Center(child: Text("No device selected"));

    // ---------------------------------------------------------------
    // DATA PREPARATION
    // ---------------------------------------------------------------
    
    // --- LAMP Data ---
    final String lampStatusText = mqttState.getSensorValue(device.deviceId, 'lamp'); // e.g. "ON", "OFF", "N/A"
    final bool isLampOn = lampStatusText.toUpperCase() == "ON";
    final DateTime? lastLampUpdate = mqttState.getLastUpdateTime(device.deviceId, 'lamp');

    bool isLampDisabled = false;
    if (_lastLampCommandTime != null) {
      // If we haven't heard back since our last command, keep it disabled
      if (lastLampUpdate == null || lastLampUpdate.isBefore(_lastLampCommandTime!)) {
        isLampDisabled = true;
      }
    }

    // --- FEEDER Data ---
    final String feederStatusText = mqttState.getSensorValue(device.deviceId, 'feeder'); // e.g. "IDLE", "FEEDING"
    final DateTime? lastFeederUpdate = mqttState.getLastUpdateTime(device.deviceId, 'feeder');
    
    bool isFeederDisabled = false;
    if (_lastFeederCommandTime != null) {
      if (lastFeederUpdate == null || lastFeederUpdate.isBefore(_lastFeederCommandTime!)) {
        isFeederDisabled = true;
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text("Control Terminal")),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // ================= FISH FEEDER CARD =================
              Card(
                elevation: 4,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    children: [
                      const Icon(Icons.set_meal, size: 60, color: Colors.orange),
                      const SizedBox(height: 10),
                      Text("Fish Feeder", style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 5),
                      
                      // --- NEW: Status Indicator ---
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.orange.withOpacity(0.5)),
                        ),
                        child: Text(
                          "Current Status: $feederStatusText", 
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.deepOrange),
                        ),
                      ),
                      
                      const SizedBox(height: 20),
                      
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.touch_app),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 15),
                            backgroundColor: Colors.orange,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: isFeederDisabled
                              ? null
                              : () {
                                  final payload = jsonEncode({"feeder": "ACTIVATE"});
                                  mqttState.sendControlCommand(device.deviceId, payload);
                                  setState(() {
                                    _lastFeederCommandTime = DateTime.now();
                                  });
                                },
                          label: Text(
                            isFeederDisabled ? "Waiting for Device..." : "Feed Now",
                            style: const TextStyle(fontSize: 18),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // ================= 12V LAMP CARD =================
              Card(
                elevation: 4,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    children: [
                      Icon(Icons.lightbulb,
                          size: 60,
                          color: isLampOn ? Colors.yellow[700] : Colors.grey),
                      const SizedBox(height: 10),
                      Text("12V Lamp", style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 5),

                      // --- NEW: Status Indicator ---
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: isLampOn ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isLampOn ? Colors.green : Colors.red,
                          ),
                        ),
                        child: Text(
                          "Current Status: $lampStatusText",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isLampOn ? Colors.green[700] : Colors.red[700],
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: Icon(isLampOn ? Icons.power_off : Icons.power),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 15),
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
                          label: Text(
                            isLampDisabled
                                ? "Syncing..."
                                : "Turn ${isLampOn ? 'OFF' : 'ON'}",
                            style: const TextStyle(fontSize: 18),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}