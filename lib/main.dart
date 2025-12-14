import 'package:aquaculture/authentication/auth_service.dart';
import 'package:aquaculture/pages/home_page.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:provider/provider.dart';

import 'firebase_options.dart';
import 'mqtt/state/mqtt_app_state.dart';
import 'authentication/auth_gate.dart';
import 'notification/firebase_msg.dart';
import 'notification/alerts_listener_service.dart';
import 'notification/alerts_service.dart';
import 'device_context.dart';

// ----------------- globals -----------------
late FirebaseMsgService firebaseMsgService;
late AlertListenerService alertListener;
final alertsService = AlertsService();

// ----------------- background handler -----------------
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  final notif = message.notification;
  final data = message.data;

  final uid = (data['uid'] ?? data['userId'])?.toString();
  final deviceId =
      (data['deviceId'] ?? data['device_id'] ?? data['device'])?.toString();

  if (uid != null && deviceId != null) {
    try {
      await alertsService.addAlert(uid, deviceId, {
        'title': notif?.title ?? data['title'] ?? 'Notification',
        'message': notif?.body ?? data['body'] ?? '',
        'sensor': data['sensor'] ?? '',
        'value': data.containsKey('value')
            ? (double.tryParse(data['value'].toString()) ?? data['value'])
            : null,
      });
    } catch (e) {
      debugPrint('❌ Failed to save background alert: $e');
    }
  }
}

// ----------------- main -----------------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Initialize FCM background handler
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Create a single instance of DeviceContext
  final deviceContext = DeviceContext();

  // Initialize services with dependencies
  firebaseMsgService = FirebaseMsgService(
    deviceContext: deviceContext,
  );
  await firebaseMsgService.init();

  alertListener = AlertListenerService();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => MQTTAppState()),
        ChangeNotifierProvider(create: (_) => deviceContext),
        Provider<AuthService>(
          create: (_) => AuthService(deviceContext: deviceContext),
        ),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aquaculture Monitoring',
      theme: ThemeData(primarySwatch: Colors.blue),
      initialRoute: '/',
      routes: {
        '/': (context) => AuthGate(),
        '/home': (context) => const HomePage(),
      },
    );
  }
}
