import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class DeviceInfo {
  final String deviceId; // e.g. "my_kedah_area1_sitea"
  final String displayTopic; // aquaculture/MY/Kedah/Area1/SiteA
  final String fcmTopic; // aquaculture_my_kedah_area1_sitea
  final Map<String, dynamic> meta;

  DeviceInfo({
    required this.deviceId,
    required this.displayTopic,
    required this.fcmTopic,
    required this.meta,
  });

  /// Convert display topic into FCM-safe topic
  static String toFcmTopic(String displayTopic) =>
      displayTopic.replaceAll('/', '_').toLowerCase();
}

class DeviceContext extends ChangeNotifier {
  // -------------------- SINGLETON --------------------
  static final DeviceContext _instance = DeviceContext._internal();
  factory DeviceContext() => _instance;
  DeviceContext._internal();
  // ---------------------------------------------------

  DeviceInfo? _selected;
  DeviceInfo? get selected => _selected;

  String? _currentUid;
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  /// Generate device ID from topic
  String generateDeviceIdFromTopic(String topic) {
    final parts = topic.split('/');
    if (parts.length < 5) return topic.toLowerCase();
    return "${parts[1]}_${parts[2]}_${parts[3]}_${parts[4]}".toLowerCase();
  }

  /// Parse topic metadata
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

  /// ✅ Create DeviceInfo from topic
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

  /// Load all devices for a user
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

  /// Set selected device, update Firestore, optionally save FCM token
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

    if (saveToken) {
      final token = await _messaging.getToken();
      if (token != null) {
        await saveFcmToken(token);
      }
    }
  }

  /// Save current FCM token under device (not under user)
  Future<void> saveFcmToken(String token) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _selected == null) return;

    final tokenDoc = FirebaseFirestore.instance
        .collection('devices')
        .doc(_selected!.deviceId)
        .collection('fcmTokens')
        .doc(user.uid);

    await tokenDoc.set({
      'email': user.email,
      'tokens': FieldValue.arrayUnion([token]),
      'lastUpdated': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    debugPrint(
      "✅ Saved FCM token for device ${_selected!.deviceId}, user ${user.uid}: $token",
    );
  }

  /// Clear selected device and user context
  void clear() {
    _selected = null;
    _currentUid = null;
    notifyListeners();
  }
}
