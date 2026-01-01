import 'package:flutter/material.dart';

class SensorData {
  final String key;
  final IconData icon;
  final String unit;
  final double? value;

  const SensorData({
    required this.key,
    required this.icon,
    required this.unit,
    required this.value,
  });
}

class SensorCard extends StatelessWidget {
  final SensorData sensor;
  final Map<String, double>? thresholds;
  final double scale; // 👈 scale factor (1.0 = normal)

  const SensorCard({
    super.key,
    required this.sensor,
    this.thresholds,
    this.scale = 1.0,
  });

  String _formatValue(String key, String displayValue, String unit) {
    switch (key.toLowerCase()) {
      case "turbidity":
        return "Level $displayValue";
      case "waterlevel":
        return "$displayValue %";
      default:
        return "$displayValue $unit";
    }
  }

  String _formatRange(String key, double min, double max, String unit) {
    switch (key.toLowerCase()) {
      case "turbidity":
        return "Range: Level ${min.toStringAsFixed(1)} - Level ${max.toStringAsFixed(1)}";
      case "waterlevel":
        return "Range: ${min.toStringAsFixed(1)} - ${max.toStringAsFixed(1)} %";
      default:
        return "Range: ${min.toStringAsFixed(1)} - ${max.toStringAsFixed(1)} $unit";
    }
  }

  @override
  Widget build(BuildContext context) {
    final min = thresholds?["min"];
    final max = thresholds?["max"];
    final hasValue = sensor.value != null && !sensor.value!.isNaN;
    final displayValue = hasValue ? sensor.value!.toStringAsFixed(2) : "N/A";

    Color iconColor;
    String statusText;

    if (!hasValue) {
      iconColor = Colors.orange;
      statusText = "⚠ No data yet";
    } else if (min != null && max != null && !min.isNaN && !max.isNaN) {
      if (sensor.value! < min) {
        iconColor = Colors.red;
        statusText = "Below min threshold";
      } else if (sensor.value! > max) {
        iconColor = Colors.red;
        statusText = "Above max threshold";
      } else {
        iconColor = Colors.green;
        statusText = "Normal";
      }
    } else {
      iconColor = Colors.orange;
      statusText = "⚠ Threshold not set";
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(12 * scale),
        child: Row(
          children: [
            Icon(sensor.icon, size: 40 * scale, color: iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Left side: Key + Value
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        sensor.key.toUpperCase(),
                        style: TextStyle(
                          fontSize: 12 * scale,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _formatValue(sensor.key, displayValue, sensor.unit),
                        style: TextStyle(
                          fontSize: 18 * scale,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  // Right side: Status + Range
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        statusText,
                        style: TextStyle(
                          fontSize: 14 * scale,
                          fontStyle: FontStyle.italic,
                          color: iconColor,
                        ),
                      ),
                      if (min != null && max != null)
                        Text(
                          _formatRange(sensor.key, min, max, sensor.unit),
                          style: TextStyle(
                            fontSize: 12 * scale,
                            color: Colors.grey,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
