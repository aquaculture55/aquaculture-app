import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../device_context.dart';
import '../mqtt/state/mqtt_app_state.dart';
import 'dart:convert';

class ControlPage extends StatefulWidget {
  const ControlPage({super.key});

  @override
  State<ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends State<ControlPage> {
  bool _isPumpOn = false; // Local state for demo, ideally sync from MQTT

  @override
  Widget build(BuildContext context) {
    final mqttState = context.watch<MQTTAppState>();
    final deviceCtx = Provider.of<DeviceContext>(context);
    final device = deviceCtx.selected;

    if (device == null) return const Center(child: Text("No device selected"));

    return Scaffold(
      appBar: AppBar(title: const Text("Control Terminal")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.power_settings_new, 
                size: 80, 
                color: _isPumpOn ? Colors.green : Colors.grey),
            const SizedBox(height: 20),
            Text("Water Pump", style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 20),
            Switch(
              value: _isPumpOn,
              onChanged: (value) {
                setState(() => _isPumpOn = value);
                
                // Construct JSON payload
                final payload = jsonEncode({"pump": value ? "ON" : "OFF"});
                
                // Send via MQTT
                mqttState.sendControlCommand(device.deviceId, payload);
              },
            ),
            const SizedBox(height: 10),
            Text(_isPumpOn ? "Status: ON" : "Status: OFF"),
          ],
        ),
      ),
    );
  }
}