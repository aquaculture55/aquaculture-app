// lib/pages/main_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // <-- For HapticFeedback
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:aquaculture/mqtt/state/mqtt_app_state.dart';
import '../device_context.dart';
import 'home_page.dart';
import 'trends_page.dart';
import 'alerts_page.dart';
import 'profile_page.dart';
import 'threshold_settings_page.dart';
import 'control_page.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  int _currentIndex = 0;
  late final PageController _pageController;
  late final TabController _trendsTabController;

  Timer? _reconnectTimer;
  Timer? _warningResetTimer;

  bool _isActive = true;
  bool _showedConnectionWarning = false;

  final List<String> _sensors = [
    "temperature",
    "ph",
    "tds",
    "turbidity",
    "waterlevel",
  ];

  final PageStorageBucket _bucket = PageStorageBucket();

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _trendsTabController = TabController(length: _sensors.length, vsync: this);
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeDeviceAndMQTT();
    });

    FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null && mounted) {
        final deviceCtx = Provider.of<DeviceContext>(context, listen: false);
        deviceCtx.clear();
        _initializeDeviceAndMQTT();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _trendsTabController.dispose();
    _reconnectTimer?.cancel();
    _warningResetTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isActive = state == AppLifecycleState.resumed;
    final mqttState = Provider.of<MQTTAppState>(context, listen: false);
    if (_isActive &&
        mqttState.appConnectionState != MQTTAppConnectionState.connected) {
      _initializeDeviceAndMQTT();
    } else {
      _reconnectTimer?.cancel();
    }
  }

  Future<void> _initializeDeviceAndMQTT({DeviceInfo? device}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !mounted) return;

    final deviceCtx = Provider.of<DeviceContext>(context, listen: false);
    final mqttState = Provider.of<MQTTAppState>(context, listen: false);

    if (device != null) {
      await deviceCtx.setSelected(device);
    } else if (deviceCtx.selected == null) {
      final subs = await deviceCtx.loadDevicesForUser(user.uid);
      if (subs.isNotEmpty) {
        await deviceCtx.setSelected(subs.first);
      }
    }

    final activeDevice = deviceCtx.selected;
    if (activeDevice == null) return;

    if (mqttState.appConnectionState == MQTTAppConnectionState.disconnected) {
      debugPrint("🔌 Connecting MQTT for ${activeDevice.deviceId}...");
      await mqttState.connect(user, activeDevice.deviceId);
      _setupReconnectWarningTimer();
    }
  }

  void _setupReconnectWarningTimer() {
    _reconnectTimer?.cancel();
    final mqttState = Provider.of<MQTTAppState>(context, listen: false);

    _reconnectTimer = Timer(const Duration(seconds: 10), () {
      if (mqttState.appConnectionState != MQTTAppConnectionState.connected &&
          mounted &&
          _isActive) {
        _showConnectionWarning();
      }
    });
  }

  void _showConnectionWarning() {
    if (_showedConnectionWarning || !mounted) return;
    _showedConnectionWarning = true;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          "⚠️ Unable to connect to MQTT. Data may be outdated.",
        ),
        backgroundColor: Colors.orange[800],
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Retry',
          onPressed: () {
            _showedConnectionWarning = false;
            _initializeDeviceAndMQTT();
          },
        ),
      ),
    );

    _warningResetTimer?.cancel();
    _warningResetTimer = Timer(const Duration(seconds: 30), () {
      _showedConnectionWarning = false;
    });
  }

  Stream<int> _alertsCountStream(String? deviceId) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || deviceId == null) return Stream.value(0);

    return FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('alerts')
        .doc(deviceId)
        .collection('logs')
        .where('read', isEqualTo: false)
        .snapshots()
        .map((snap) => snap.docs.length);
  }

  AppBar _buildAppBar(MQTTAppState mqttState) {
    final deviceCtx = Provider.of<DeviceContext>(context, listen: false);
    final deviceId = deviceCtx.selected?.deviceId;
    final user = FirebaseAuth.instance.currentUser;

    return AppBar(
      automaticallyImplyLeading: false,
      flexibleSpace: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color.fromARGB(255, 45, 82, 183), // deep blue
              Color(0xFF2563EB), // medium blue
              Color(0xFF60A5FA), // light sky blue
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      ),
      title: const Text(
        "Aquaculture Monitoring",
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
      actions: [
        if (_currentIndex == 3 && user != null && deviceId != null)
          IconButton(
            icon: const Icon(Icons.delete_forever, color: Colors.white),
            tooltip: 'Delete all alerts',
            onPressed: () {
              HapticFeedback.lightImpact();
              _confirmDeleteAllAlerts(user.uid, deviceId);
            },
          ),
        IconButton(
          icon: const Icon(Icons.devices_other, color: Colors.white),
          tooltip: 'Select device',
          onPressed: () {
            HapticFeedback.lightImpact();
            _showDevicePicker();
          },
        ),
        IconButton(
          icon: const Icon(Icons.settings, color: Colors.white),
          tooltip: 'Threshold Settings',
          onPressed: () async {
            HapticFeedback.lightImpact();
            if (!mounted) return;
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ThresholdSettingsPage()),
            );
          },
        ),
        Icon(
          mqttState.appConnectionState == MQTTAppConnectionState.connected
              ? Icons.cloud_done
              : Icons.cloud_off,
          color:
              mqttState.appConnectionState == MQTTAppConnectionState.connected
              ? Colors.greenAccent
              : Colors.redAccent,
        ),
        const SizedBox(width: 8),
      ],
      bottom: _currentIndex == 1 && _sensors.isNotEmpty
          ? TabBar(
              controller: _trendsTabController,
              isScrollable: true,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              indicatorColor: Colors.white,
              tabs: _sensors
                  .map((s) => Tab(text: s == 'ph' ? 'pH' : s.toUpperCase()))
                  .toList(),
            )
          : null,
    );
  }

  Future<void> _confirmDeleteAllAlerts(String uid, String deviceId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.black,
        title: const Text(
          "Delete All Alerts",
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          "⚠️ This will permanently delete all alerts for this device.\n\nAre you sure?",
          style: TextStyle(color: Colors.yellow),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel", style: TextStyle(color: Colors.white)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              "Delete All",
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _deleteAllAlerts(uid, deviceId);
    }
  }

  Future<void> _deleteAllAlerts(String uid, String deviceId) async {
    final logsRef = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('alerts')
        .doc(deviceId)
        .collection('logs');

    final batch = FirebaseFirestore.instance.batch();
    final snapshot = await logsRef.get();
    for (final doc in snapshot.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('✅ All alerts deleted')));
    }
  }

  Future<void> _showDevicePicker() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final subs = await Provider.of<DeviceContext>(
      context,
      listen: false,
    ).loadDevicesForUser(user.uid);

    if (!mounted || subs.isEmpty) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true, // allow full height
      backgroundColor: Colors.transparent,
      isDismissible: true, // allows tapping outside to dismiss
      enableDrag: true, // allow drag to dismiss
      builder: (ctx) => GestureDetector(
        behavior: HitTestBehavior.opaque, // detect taps outside
        onTap: () => Navigator.of(ctx).pop(), // dismiss when tapping outside
        child: DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.8,
          builder: (_, controller) => GestureDetector(
            // prevent closing when tapping inside sheet
            onTap: () {},
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: ListView.separated(
                controller: controller,
                itemCount: subs.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (c, i) {
                  final d = subs[i];
                  final label = d.meta.isNotEmpty
                      ? '${d.meta['site'] ?? d.deviceId} — ${d.meta['area'] ?? ''}, ${d.meta['district'] ?? ''}'
                      : d.deviceId;

                  return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder: (child, anim) =>
                        FadeTransition(opacity: anim, child: child),
                    child: ListTile(
                      key: ValueKey(d.deviceId),
                      title: Text(label),
                      subtitle: Text(d.displayTopic),
                      trailing:
                          Provider.of<DeviceContext>(
                                context,
                                listen: false,
                              ).selected?.deviceId ==
                              d.deviceId
                          ? const Icon(Icons.check, color: Colors.blue)
                          : null,
                      onTap: () async {
                        Provider.of<DeviceContext>(
                          context,
                          listen: false,
                        ).setSelected(d);
                        Navigator.pop(ctx);
                        await _initializeDeviceAndMQTT(device: d);
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mqttState = context.watch<MQTTAppState>();
    final deviceCtx = Provider.of<DeviceContext>(context);
    final deviceId = deviceCtx.selected?.deviceId;
    final user = FirebaseAuth.instance.currentUser;

    final pages = [
      const HomePage(),
      TrendsPage(
        tabController: _trendsTabController,
        sensors: _sensors,
        deviceId: deviceId ?? '',
      ),
      const ControlPage(),
      AlertsPage(deviceId: deviceId ?? ''),
      const ProfilePage(),
    ];

    return Scaffold(
      appBar: _buildAppBar(mqttState),
      body: PageView.builder(
        controller: _pageController,
        itemCount: pages.length,
        physics: const BouncingScrollPhysics(),
        onPageChanged: (index) {
          HapticFeedback.lightImpact(); // vibrate on page switch
          setState(() => _currentIndex = index);
        },
        itemBuilder: (context, index) {
          return AnimatedBuilder(
            animation: _pageController,
            builder: (context, child) {
              double value = 1.0;
              if (_pageController.position.haveDimensions) {
                value = (_pageController.page! - index);
                value = (1 - (value.abs() * 0.1)).clamp(0.0, 1.0);
              }
              return Transform.scale(
                scale: Curves.easeOut.transform(value),
                child: child,
              );
            },
            child: PageStorage(bucket: _bucket, child: pages[index]),
          );
        },
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color.fromARGB(255, 45, 82, 183),
              Color(0xFF2563EB),
              Color(0xFF60A5FA),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: BottomNavigationBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          currentIndex: _currentIndex,
          onTap: (index) {
            HapticFeedback.lightImpact(); // vibrate on tab switch
            _pageController.animateToPage(
              index,
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeInOutCubic,
            );
          },
          type: BottomNavigationBarType.fixed,
          selectedItemColor: Colors.white,
          unselectedItemColor: Colors.white70,
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.widgets),
              label: 'Widgets',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.show_chart),
              label: 'Trends',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.gamepad), // Or Icons.toggle_on
              label: 'Control',
            ),
            BottomNavigationBarItem(
              icon: StreamBuilder<int>(
                stream: _alertsCountStream(deviceId),
                builder: (context, snapshot) {
                  final count = snapshot.data ?? 0;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(Icons.notifications, size: 28),
                      if (count > 0)
                        Positioned(
                          right: -6,
                          top: -3,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            constraints: const BoxConstraints(
                              minWidth: 16,
                              minHeight: 16,
                            ),
                            child: Text(
                              '$count',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              label: 'Alerts',
            ),
            BottomNavigationBarItem(
              icon: CircleAvatar(
                radius: 12,
                backgroundImage: user?.photoURL != null
                    ? NetworkImage(user!.photoURL!)
                    : null,
                child: user?.photoURL == null
                    ? const Icon(Icons.person, size: 16)
                    : null,
              ),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}
