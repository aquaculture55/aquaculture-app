// lib/device_context.dart
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class DeviceInfo {
  final String deviceId;
  final String displayTopic;
  final String fcmTopic;
  final Map<String, dynamic> meta;

  DeviceInfo({
    required this.deviceId,
    required this.displayTopic,
    required this.fcmTopic,
    required this.meta,
  });

  static String toFcmTopic(String displayTopic) =>
      displayTopic.replaceAll('/', '_').toLowerCase();
}

class DeviceContext extends ChangeNotifier {
  static final DeviceContext _instance = DeviceContext._internal();
  factory DeviceContext() => _instance;
  DeviceContext._internal();

  DeviceInfo? _selected;
  DeviceInfo? get selected => _selected;

  String? _currentUid;
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  String generateDeviceIdFromTopic(String topic) {
    final parts = topic.split('/');
    if (parts.length < 5) return topic.toLowerCase();
    return "${parts[1]}_${parts[2]}_${parts[3]}_${parts[4]}".toLowerCase();
  }

  Map<String, dynamic> parseTopicMeta(String topic) {
    final parts = topic.split('/');
    if (parts.length < 5) return {};
    return {
      'state': parts[1],
      'district': parts[2],
      'area': parts[3],
      'site': parts[4],
    };
  }

  DeviceInfo createDeviceInfoFromTopic(
    String topic,
    Map<String, dynamic> meta,
  ) {
    final deviceId = generateDeviceIdFromTopic(topic);
    final fcmTopic = DeviceInfo.toFcmTopic(topic);

    return DeviceInfo(
      deviceId: deviceId,
      displayTopic: topic,
      fcmTopic: fcmTopic,
      meta: {
        'state': meta['state'] ?? parseTopicMeta(topic)['state'],
        'district': meta['district'] ?? parseTopicMeta(topic)['district'],
        'area': meta['area'] ?? parseTopicMeta(topic)['area'],
        'site': meta['site'] ?? parseTopicMeta(topic)['site'],
      },
    );
  }

  Future<List<DeviceInfo>> loadDevicesForUser(
    String uid, {
    String? newTopic,
  }) async {
    if (_currentUid != uid) {
      _currentUid = uid;
      _selected = null;
      notifyListeners();
    }

    final snap = await FirebaseFirestore.instance
        .collection('devices')
        .where('members', arrayContains: uid)
        .get();

    List<DeviceInfo> devices = snap.docs
        .map((doc) {
          final data = doc.data();
          final topic = data['topic'] as String? ?? '';
          if (topic.isEmpty) return null;
          return createDeviceInfoFromTopic(topic, data);
        })
        .whereType<DeviceInfo>()
        .toList();

    if (newTopic != null && !devices.any((d) => d.displayTopic == newTopic)) {
      final meta = parseTopicMeta(newTopic);
      final newDevice = createDeviceInfoFromTopic(newTopic, meta);
      await setSelected(newDevice, saveToken: true);
      devices.add(newDevice);
    }

    return devices;
  }

  Future<void> setSelected(DeviceInfo info, {bool saveToken = false}) async {
    _selected = info;
    notifyListeners();

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final deviceDoc =
        FirebaseFirestore.instance.collection('devices').doc(info.deviceId);
    final meta = info.meta;

    final keywords = <String>{
      (meta['state'] ?? '').toString().toLowerCase(),
      (meta['district'] ?? '').toString().toLowerCase(),
      (meta['area'] ?? '').toString().toLowerCase(),
      (meta['site'] ?? '').toString().toLowerCase(),
    }..removeWhere((k) => k.isEmpty);

    await deviceDoc.set({
      'topic': info.displayTopic,
      'fcmTopic': info.fcmTopic,
      'keywords': keywords.toList(),
      'owner': user.uid,
      'members': FieldValue.arrayUnion([user.uid]),
      'state': meta['state'],
      'district': meta['district'],
      'area': meta['area'],
      'site': meta['site'],
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'lastSelectedDevice': info.deviceId,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint("⚠️ Failed to save last selected device: $e");
    }

    if (saveToken) {
      final token = await _messaging.getToken();
      if (token != null) {
        await saveFcmToken(token);
      }
    }
  }

  /// ✅ FIXED: Save Token to users/{uid}/fcmTokens/{deviceId}
  /// This matches where the Cloudflare Worker looks for it.
  Future<void> saveFcmToken(String token) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _selected == null) return;

    final tokenDoc = FirebaseFirestore.instance
        .collection('users') // Changed from 'devices' to 'users'
        .doc(user.uid)
        .collection('fcmTokens')
        .doc(_selected!.deviceId);

    await tokenDoc.set({
      'email': user.email,
      'fcmTokens': FieldValue.arrayUnion([token]),
      'lastUpdated': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    debugPrint(
      "✅ Saved FCM token for Worker at users/${user.uid}/fcmTokens/${_selected!.deviceId}",
    );
  }

  void clear() {
    _selected = null;
    _currentUid = null;
    notifyListeners();
  }
}