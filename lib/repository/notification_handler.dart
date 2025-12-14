import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationHandler {
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  NotificationHandler() {
    _init();
  }

  void _init() {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    _notifications.initialize(settings);
  }

  Future<void> showAlertNotification(String title, String body) async {
    const android = AndroidNotificationDetails(
      'alerts_channel',
      'Alerts',
      channelDescription: 'Notification channel for alerts',
      importance: Importance.max,
      priority: Priority.high,
    );

    const details = NotificationDetails(android: android);

    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
    );
  }
}
