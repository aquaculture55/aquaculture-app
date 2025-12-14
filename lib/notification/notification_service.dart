import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';

class NotiService {
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  NotiService();

  Future<void> initNotifications() async {
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('notification_icon'); // ✅ use drawable

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
  }

  Future<void> showNotification({
    required String title,
    required String body,
  }) async {
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
          icon: 'notification_icon', // ✅ explicitly set icon
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

