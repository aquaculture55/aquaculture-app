import 'package:aquaculture/mqtt/state/mqtt_app_state.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../device_context.dart';

class DevicePickerPage extends StatefulWidget {
  const DevicePickerPage({super.key});

  @override
  State<DevicePickerPage> createState() => _DevicePickerPageState();
}

class _DevicePickerPageState extends State<DevicePickerPage> {
  final TextEditingController _topicController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _firestore = FirebaseFirestore.instance;

  bool _loading = false;
  static const topicFormat = 'aquaculture/<state>/<district>/<area>/<site>';

  Future<void> _selectTopic(String topic) async {
    // Close the picker immediately
    if (!mounted) return;
    Navigator.pop(context);

    setState(() => _loading = true);

    try {
      final parts = topic.split('/');
      if (parts.length != 5 || parts[0] != 'aquaculture') {
        throw Exception('Invalid topic format');
      }

      final fcmTopic = DeviceInfo.toFcmTopic(topic);
      final deviceCtx = Provider.of<DeviceContext>(context, listen: false);
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception("Not logged in");

      // Prepare async tasks
      final firestoreQuery = _firestore
          .collection('devices')
          .where('state', isEqualTo: parts[1])
          .where('district', isEqualTo: parts[2])
          .where('area', isEqualTo: parts[3])
          .where('site', isEqualTo: parts[4])
          .limit(1)
          .get();

      final fcmSubscribe = FirebaseMessaging.instance.subscribeToTopic(
        fcmTopic,
      );

      // Wait for Firestore query
      final snapshot = await firestoreQuery;
      DeviceInfo deviceInfo;

      if (snapshot.docs.isEmpty) {
        final meta = {
          'state': parts[1],
          'district': parts[2],
          'area': parts[3],
          'site': parts[4],
        };
        deviceInfo = deviceCtx.createDeviceInfoFromTopic(topic, meta);
      } else {
        final deviceDoc = snapshot.docs.first;
        deviceInfo = deviceCtx.createDeviceInfoFromTopic(
          topic,
          deviceDoc.data(),
        );
      }

      // Set selected device immediately (optimistic)
      await deviceCtx.setSelected(deviceInfo, saveToken: true);

      // Firestore user devices update + FCM + MQTT in parallel
      await Future.wait([
        fcmSubscribe,
        _firestore
            .collection('users')
            .doc(user.uid)
            .collection('devices')
            .doc(deviceInfo.deviceId)
            .set({
              'state': deviceInfo.meta['state'],
              'district': deviceInfo.meta['district'],
              'area': deviceInfo.meta['area'],
              'site': deviceInfo.meta['site'],
              'linkedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true)),
        Provider.of<MQTTAppState>(
          context,
          listen: false,
        ).connect(user, deviceInfo.deviceId),
      ]);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error selecting device: ${e.toString()}')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<String>> _getSuggestions(String pattern) async {
    if (pattern.isEmpty) return [];
    final snapshot = await _firestore
        .collection('devices')
        .where('state', isGreaterThanOrEqualTo: pattern)
        .where('state', isLessThanOrEqualTo: '$pattern\uf8ff')
        .get();

    return snapshot.docs.map((doc) {
      final state = doc['state'] ?? '';
      final district = doc['district'] ?? '';
      final area = doc['area'] ?? '';
      final site = doc['site'] ?? '';
      return 'aquaculture/$state/$district/$area/$site';
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('Please log in to see your devices')),
      );
    }

    final devicesStream = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('devices')
        .orderBy('linkedAt', descending: true)
        .snapshots();

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Subscribe to Topic',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xFF2563EB),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      // FIX: Wrap the body in SingleChildScrollView to allow scrolling
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Topic Format:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  topicFormat,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(height: 16),

                // ... (Your Autocomplete widget stays the same) ...
                Autocomplete<String>(
                  optionsBuilder: (TextEditingValue textEditingValue) async {
                    return await _getSuggestions(textEditingValue.text);
                  },
                  onSelected: (selection) {
                    _topicController.text = selection;
                    _topicController.selection = TextSelection.fromPosition(
                      TextPosition(offset: _topicController.text.length),
                    );
                  },
                  fieldViewBuilder:
                      (context, controller, focusNode, onEditingComplete) {
                        return TextFormField(
                          controller: _topicController,
                          focusNode: focusNode,
                          decoration: const InputDecoration(
                            labelText: 'Enter Topic',
                            hintText: 'e.g. aquaculture/MY/Kedah/Area1/SiteA',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Topic cannot be empty';
                            }
                            // Simplified regex check for brevity in this snippet
                            if (!value.contains('/')) {
                              return 'Invalid format';
                            }
                            return null;
                          },
                        );
                      },
                ),
                const SizedBox(height: 24),

                SizedBox(
                  width: double.infinity,
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : ElevatedButton.icon(
                          icon: const Icon(Icons.check, color: Colors.white),
                          label: const Text('Confirm'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2563EB),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(30),
                            ),
                          ),
                          onPressed: () {
                            FocusScope.of(context).unfocus();
                            if (_formKey.currentState!.validate()) {
                              _selectTopic(_topicController.text.trim());
                            }
                          },
                        ),
                ),
                const SizedBox(height: 24),

                // History Devices
                StreamBuilder<QuerySnapshot>(
                  stream: devicesStream,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final docs = snapshot.data!.docs;
                    if (docs.isEmpty) return const SizedBox();

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Your Devices:',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        // Wrap allows items to flow to next line,
                        // and SingleChildScrollView allows scrolling down
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: docs.map((doc) {
                            final state = doc['state'] ?? '';
                            final district = doc['district'] ?? '';
                            final area = doc['area'] ?? '';
                            final site = doc['site'] ?? '';
                            final topic =
                                'aquaculture/$state/$district/$area/$site';

                            return InkWell(
                              onTap: () => _selectTopic(topic),
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.blue.shade50,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Colors.blue.shade200,
                                  ),
                                ),
                                child: Text(
                                  topic,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Colors.black87,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.visible,
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        // Add some extra padding at the bottom for better scrolling experience
                        const SizedBox(height: 20),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
