import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import '../device_context.dart';

class ThresholdSettingsPage extends StatefulWidget {
  const ThresholdSettingsPage({super.key});

  @override
  State<ThresholdSettingsPage> createState() => _ThresholdSettingsPageState();
}

class _ThresholdSettingsPageState extends State<ThresholdSettingsPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Default thresholds
  final Map<String, Map<String, double>> _defaultPreset = {
    "temperature": {"min": 20, "max": 40},
    "ph": {"min": 1, "max": 14},
    "tds": {"min": 0, "max": 1000},
    "turbidity": {"min": 1, "max": 10},
    "waterlevel": {"min": 0, "max": 100},
  };

  final List<String> _sensors = ["temperature", "ph", "tds", "turbidity", "waterlevel"];

  Map<String, Map<String, double>> _thresholds = {};
  final Map<String, TextEditingController> _controllers = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Start with defaults
    _applyThresholds(_defaultPreset);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadThresholds());
  }

  Future<void> _loadThresholds() async {
    final user = _auth.currentUser;
    final deviceCtx = Provider.of<DeviceContext>(context, listen: false);
    final deviceId = deviceCtx.selected?.deviceId;

    if (user == null || deviceId == null) return;

    try {
      final doc = await _firestore
          .collection("users")
          .doc(user.uid)
          .collection("thresholds")
          .doc(deviceId)
          .get();

      if (doc.exists && doc.data() != null) {
        final loaded = <String, Map<String, double>>{};
        final data = doc.data()!;
        for (final s in _sensors) {
          final v = data[s];
          if (v is Map) {
            loaded[s] = {
              "min": (v['min'] ?? _defaultPreset[s]!['min']!).toDouble(),
              "max": (v['max'] ?? _defaultPreset[s]!['max']!).toDouble(),
            };
          }
        }
        _applyThresholds(loaded.isNotEmpty ? loaded : _defaultPreset);
      }
    } catch (e) {
      debugPrint("Load thresholds error: $e");
      _applyThresholds(_defaultPreset);
    }
  }

  void _applyThresholds(Map<String, Map<String, double>> newValues) {
    setState(() {
      // deep copy → guarantees mutability
      _thresholds = {
        for (var entry in newValues.entries)
          entry.key: Map<String, double>.from(entry.value)
      };
      _initializeControllers();
      _loading = false;
    });
  }

  void _initializeControllers() {
    _controllers.clear();
    for (var s in _sensors) {
      final minVal = _thresholds[s]?["min"] ?? _defaultPreset[s]!["min"]!;
      final maxVal = _thresholds[s]?["max"] ?? _defaultPreset[s]!["max"]!;
      _controllers["${s}_min"] = TextEditingController(text: minVal.toString());
      _controllers["${s}_max"] = TextEditingController(text: maxVal.toString());
    }
  }

  Future<void> _saveThresholds() async {
    final user = _auth.currentUser;
    final deviceCtx = Provider.of<DeviceContext>(context, listen: false);
    final deviceId = deviceCtx.selected?.deviceId;
    if (user == null || deviceId == null) return;

    final updated = <String, Map<String, double>>{};
    for (var s in _sensors) {
      final min = double.tryParse(_controllers["${s}_min"]?.text ?? '') ?? _defaultPreset[s]!["min"]!;
      final max = double.tryParse(_controllers["${s}_max"]?.text ?? '') ?? _defaultPreset[s]!["max"]!;

      if (min >= max) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Invalid range for $s (min < max)")),
          );
        }
        return;
      }
      updated[s] = {"min": min, "max": max};
    }

    try {
      await _firestore
          .collection("users")
          .doc(user.uid)
          .collection("thresholds")
          .doc(deviceId)
          .set({
            ...updated,
            "timestamp": FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      _applyThresholds(updated);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Thresholds saved successfully")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error saving thresholds: $e")),
        );
      }
    }
  }

  void _resetToDefaults() {
    final copy = {
      for (var entry in _defaultPreset.entries)
        entry.key: Map<String, double>.from(entry.value)
    };
    _applyThresholds(copy);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Reset to default preset")),
      );
    }
    _saveThresholds();
  }

  Future<void> _reloadFromFirestore() async {
    setState(() => _loading = true);
    await _loadThresholds();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Reloaded saved thresholds")),
      );
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(title: const Text("Threshold Settings")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            for (var s in _sensors)
              Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: LayoutBuilder(builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final fontScale = width / 360;

                    final sMin = (_defaultPreset[s]?["min"] ?? 0).toDouble();
                    final sMax = (_defaultPreset[s]?["max"] ?? 100).toDouble();

                    final curMin = (_thresholds[s]?["min"] ?? sMin).clamp(sMin, sMax);
                    final curMax = (_thresholds[s]?["max"] ?? sMax).clamp(sMin, sMax);

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.toUpperCase(),
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14 * fontScale),
                        ),
                        const SizedBox(height: 4),
                        RangeSlider(
                          min: sMin,
                          max: sMax,
                          divisions: 100,
                          values: RangeValues(curMin, curMax),
                          labels: RangeLabels(curMin.toStringAsFixed(1), curMax.toStringAsFixed(1)),
                          onChanged: (values) {
                            HapticFeedback.lightImpact();
                            setState(() {
                              // always replace with a fresh mutable map
                              final current = Map<String, double>.from(_thresholds[s] ?? {"min": sMin, "max": sMax});
                              current["min"] = values.start;
                              current["max"] = values.end;

                              _thresholds[s] = current; // reassign the fresh copy

                              _controllers["${s}_min"]!.text = values.start.toStringAsFixed(1);
                              _controllers["${s}_max"]!.text = values.end.toStringAsFixed(1);
                            });
                          },
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text("Min: ${curMin.toStringAsFixed(1)}",
                                style: TextStyle(fontSize: 12 * fontScale)),
                            Text("Max: ${curMax.toStringAsFixed(1)}",
                                style: TextStyle(fontSize: 12 * fontScale)),
                          ],
                        ),
                      ],
                    );
                  }),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _saveThresholds,
                    icon: const Icon(Icons.save),
                    label: const Text("Save"),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _resetToDefaults,
                    icon: const Icon(Icons.refresh),
                    label: const Text("Reset"),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _reloadFromFirestore,
                    icon: const Icon(Icons.cloud_download),
                    label: const Text("Load Saved"),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
