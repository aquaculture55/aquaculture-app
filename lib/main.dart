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

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  final deviceContext = DeviceContext();

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

// --- CHANGED: Converted to StatefulWidget to handle Lifecycle ---
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  
  @override
  void initState() {
    super.initState();
    // Register this class to observe app lifecycle (Background/Foreground)
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When app resumes (user opens it again), check connections
    if (state == AppLifecycleState.resumed) {
      debugPrint("📱 App Resumed - Checking MQTT Connection...");
      // Ideally, your MQTTAppState should have a method to reconnect if disconnected
      // final mqttState = Provider.of<MQTTAppState>(context, listen: false);
      // if (mqttState.appConnectionState == MQTTAppConnectionState.disconnected) {
      //    mqttState.connect(...); // Logic to reconnect if needed
      // }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aquaculture Monitoring',
      theme: ThemeData(primarySwatch: Colors.blue),
      initialRoute: '/',
      routes: {
        '': (context) => AuthGate(), // Fixed route name from '/'
        '/home': (context) => const HomePage(),
      },
      home: AuthGate(), // Added home explicit
    );
  }
}