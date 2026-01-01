// lib/notification/notification_service.dart
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';

class NotiService {
  // 1. Create a private static instance
  static final NotiService _instance = NotiService._internal();

  // 2. Factory constructor returns the same instance every time
  factory NotiService() => _instance;

  // 3. Internal constructor
  NotiService._internal();

  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;

  Future<void> initNotifications() async {
    if (_isInitialized) return; // Prevent re-initialization

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher'); 
        // Note: Ensure you have an icon named 'ic_launcher' or use '@mipmap/ic_launcher' (default flutter icon)

    const InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
    );

    await _flutterLocalNotificationsPlugin.initialize(initSettings);

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'alerts_channel',
      'Alerts',
      description: 'Important sensor alerts',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );

    await _flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    
    _isInitialized = true;
    debugPrint("✅ Local Notifications Initialized");
  }

  Future<void> showNotification({
    required String title,
    required String body,
  }) async {
    if (!_isInitialized) {
        // Fallback: try to init if not ready
        debugPrint("⚠ NotiService not initialized, trying to init now...");
        await initNotifications();
    }

    debugPrint("📢 Showing notification: $title");

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'alerts_channel',
          'Alerts',
          channelDescription: 'Important sensor alerts',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          icon: '@mipmap/ic_launcher', // Match the init icon
        );

    const NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
    );

    await _flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      platformDetails,
    );
  }
}