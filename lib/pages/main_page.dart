// lib/pages/main_page.dart
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  // ... (Lifecycle and MQTT methods remain unchanged)
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
      await deviceCtx.setSelected(device, saveToken: true);
    } else if (deviceCtx.selected == null) {
      final subs = await deviceCtx.loadDevicesForUser(user.uid);
      if (subs.isNotEmpty) {
        DeviceInfo targetDevice = subs.first;
        try {
          final userDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get();
          if (userDoc.exists) {
            final lastId = userDoc.data()?['lastSelectedDevice'];
            if (lastId != null) {
              targetDevice = subs.firstWhere(
                (d) => d.deviceId == lastId,
                orElse: () => subs.first,
              );
            }
          }
        } catch (e) {
          debugPrint("⚠️ Error loading last device preference: $e");
        }
        await deviceCtx.setSelected(targetDevice, saveToken: true);
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

  Future<void> _markAlertsAsRead() async {
    final deviceCtx = Provider.of<DeviceContext>(context, listen: false);
    final deviceId = deviceCtx.selected?.deviceId;
    final user = FirebaseAuth.instance.currentUser;

    if (user == null || deviceId == null) return;

    final qs = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('alerts')
        .doc(deviceId)
        .collection('logs')
        .where('read', isEqualTo: false)
        .get();

    if (qs.docs.isEmpty) return;

    final batch = FirebaseFirestore.instance.batch();
    for (var doc in qs.docs) {
      batch.update(doc.reference, {'read': true});
    }
    await batch.commit();
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

  // ... (Helper methods: _alertsCountStream, _confirmDeleteAllAlerts, _deleteAllAlerts, _showDevicePicker) ...
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

  Future<void> _confirmDeleteAllAlerts(String uid, String deviceId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Delete All Alerts"),
        content: const Text("This will permanently delete all alerts. Sure?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Delete All"),
          ),
        ],
      ),
    );
    if (confirmed == true) await _deleteAllAlerts(uid, deviceId);
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
    for (final doc in snapshot.docs) batch.delete(doc.reference);
    await batch.commit();
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('✅ Alerts deleted')));
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
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: MediaQuery.of(context).size.height * 0.6,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              "Select Device",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const Divider(),
            Expanded(
              child: ListView.separated(
                itemCount: subs.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, indent: 16, endIndent: 16),
                itemBuilder: (c, i) {
                  final d = subs[i];
                  final label = d.meta.isNotEmpty
                      ? '${d.meta['site'] ?? d.deviceId} — ${d.meta['area'] ?? ''}'
                      : d.deviceId;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 4,
                    ),
                    title: Text(
                      label,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    subtitle: Text(
                      d.displayTopic,
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    trailing:
                        Provider.of<DeviceContext>(
                              context,
                              listen: false,
                            ).selected?.deviceId ==
                            d.deviceId
                        ? const Icon(Icons.check_circle, color: Colors.blue)
                        : null,
                    onTap: () async {
                      Provider.of<DeviceContext>(
                        context,
                        listen: false,
                      ).setSelected(d);
                      Navigator.pop(ctx);
                      await _initializeDeviceAndMQTT(device: d);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- APP BAR ---
  AppBar _buildAppBar(MQTTAppState mqttState) {
    final deviceCtx = Provider.of<DeviceContext>(context, listen: false);
    final deviceId = deviceCtx.selected?.deviceId;
    final user = FirebaseAuth.instance.currentUser;
    final bool showTabs = _currentIndex == 1 && _sensors.isNotEmpty;

    return AppBar(
      automaticallyImplyLeading: false,
      elevation: 4,
      shadowColor: Colors.blue.withOpacity(0.3),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
      ),
      flexibleSpace: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1565C0), Color(0xFF42A5F5)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Aquaculture",
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 0.8,
                  ),
                ),
                if (deviceCtx.selected != null)
                  Text(
                    deviceCtx.selected!.meta['site'] ?? 'Monitoring',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white70,
                      fontWeight: FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_currentIndex == 3 && user != null && deviceId != null)
              _buildAppBarAction(
                icon: Icons.delete_sweep_rounded,
                tooltip: 'Delete alerts',
                onTap: () {
                  HapticFeedback.lightImpact();
                  _confirmDeleteAllAlerts(user.uid, deviceId);
                },
              ),
            _buildAppBarAction(
              icon: Icons.devices_rounded,
              tooltip: 'Switch Device',
              onTap: () {
                HapticFeedback.lightImpact();
                _showDevicePicker();
              },
            ),
            _buildAppBarAction(
              icon: Icons.settings_rounded,
              tooltip: 'Settings',
              onTap: () async {
                HapticFeedback.lightImpact();
                if (!mounted) return;
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ThresholdSettingsPage(),
                  ),
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 12),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  mqttState.appConnectionState ==
                          MQTTAppConnectionState.connected
                      ? Icons.cloud_done_rounded
                      : Icons.cloud_off_rounded,
                  color:
                      mqttState.appConnectionState ==
                          MQTTAppConnectionState.connected
                      ? const Color(0xFF69F0AE)
                      : const Color(0xFFFF8A80),
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      ],
      bottom: showTabs
          ? PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: TabBar(
                  controller: _trendsTabController,
                  isScrollable: true,
                  dividerColor: Colors.transparent,
                  labelColor: const Color(0xFF1565C0),
                  unselectedLabelColor: Colors.white70,
                  labelStyle: const TextStyle(fontWeight: FontWeight.bold),
                  indicator: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  indicatorSize: TabBarIndicatorSize.tab,
                  tabs: _sensors
                      .map(
                        (s) => Tab(
                          height: 32,
                          text: s == 'ph' ? ' pH ' : ' ${s.toUpperCase()} ',
                        ),
                      )
                      .toList(),
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildAppBarAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(50),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withOpacity(0.2),
                width: 1,
              ),
            ),
            child: Icon(icon, color: Colors.white, size: 20),
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
      backgroundColor: Colors.grey[50],
      extendBody: true, // Allows the nav bar to float
      appBar: _currentIndex == 4 ? null : _buildAppBar(mqttState),

      // ✅ FIX: Wrap PageView in Padding to push content up
      // 120px is enough to clear the 100px navigation stack + spacing
      body: Padding(
        padding: const EdgeInsets.only(bottom: 120),
        child: PageView.builder(
          controller: _pageController,
          itemCount: pages.length,
          physics: _currentIndex == 1 
              ? const NeverScrollableScrollPhysics() 
              : const BouncingScrollPhysics(),
          
          onPageChanged: (index) {
            if (_currentIndex != index) {
              HapticFeedback.lightImpact();
              setState(() => _currentIndex = index);
              if (index == 3) {
                _markAlertsAsRead();
              }
            }
          },
          itemBuilder: (context, index) {
            return FadeTransition(
              opacity: const AlwaysStoppedAnimation(1),
              child: PageStorage(bucket: _bucket, child: pages[index]),
            );
          },
        ),
      ),

      // Your existing custom nav bar
      bottomNavigationBar: _buildCustomNavBar(deviceId, user),
    );
  }

  // --- NEW: Custom Floating Navigation Bar Logic ---
  Widget _buildCustomNavBar(String? deviceId, User? user) {
    return Container(
      height: 100, // Allocate height for the floating button
      color: Colors.transparent,
      child: Stack(
        alignment: Alignment.bottomCenter,
        clipBehavior: Clip.none,
        children: [
          // 1. The Background Pill
          Container(
            height: 70,
            margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(35),
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF2563EB),
                  Color(0xFF1D4ED8),
                ], // Signature Blue
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.blue.withOpacity(0.3),
                  blurRadius: 15,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Left Side
                _buildNavItem(0, Icons.grid_view_rounded, "Home"),
                _buildNavItem(1, Icons.show_chart_rounded, "Trends"),

                // GAP for the middle button
                const SizedBox(width: 60),

                // Right Side
                _buildNavItem(
                  3,
                  _buildAlertIcon(deviceId, _currentIndex == 3),
                  "Alerts",
                  isWidget: true,
                ),
                _buildNavItem(
                  4,
                  _buildProfileIcon(user, _currentIndex == 4),
                  "Profile",
                  isWidget: true,
                ),
              ],
            ),
          ),

          // 2. The Floating Control Button
          Positioned(
            bottom: 45, // Raises it above the bar
            child: GestureDetector(
              onTap: () => _onItemTapped(2),
              child: Container(
                height: 70,
                width: 70,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors
                      .grey[50], // Match scaffold background for cutout effect
                  boxShadow: [
                    BoxShadow(
                      color: Colors.blue.withOpacity(0.4),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(5), // Thickness of white ring
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: _currentIndex == 2
                          ? [
                              Colors.orange.shade400,
                              Colors.deepOrange,
                            ] // Active Color
                          : [
                              const Color(0xFF1565C0),
                              const Color(0xFF42A5F5),
                            ], // Default Blue
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: const Icon(
                    Icons.gamepad_rounded,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Helper for Nav Items
  Widget _buildNavItem(
    int index,
    dynamic iconOrWidget,
    String label, {
    bool isWidget = false,
  }) {
    final bool isSelected = _currentIndex == index;

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _onItemTapped(index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            isWidget
                ? iconOrWidget
                : Icon(
                    iconOrWidget,
                    color: isSelected ? Colors.white : Colors.white54,
                    size: isSelected ? 28 : 24,
                  ),
            const SizedBox(height: 4),
            if (isSelected)
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _onItemTapped(int index) {
    HapticFeedback.lightImpact();
    setState(() => _currentIndex = index);
    _pageController.jumpToPage(index);
    if (index == 3) {
      _markAlertsAsRead();
    }
  }

  // Helper for Alert Icon
  Widget _buildAlertIcon(String? deviceId, bool isActive) {
    return StreamBuilder<int>(
      stream: _alertsCountStream(deviceId),
      builder: (context, snapshot) {
        final count = snapshot.data ?? 0;
        final iconSize = isActive ? 28.0 : 24.0;
        final color = isActive ? Colors.white : Colors.white54;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(
              isActive
                  ? Icons.notifications_rounded
                  : Icons.notifications_none_rounded,
              size: iconSize,
              color: color,
            ),
            if (count > 0)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.redAccent,
                    shape: BoxShape.circle,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 16,
                    minHeight: 16,
                  ),
                  child: Center(
                    child: Text(
                      count > 9 ? '9+' : '$count',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  // Helper for Profile Icon
  Widget _buildProfileIcon(User? user, bool isActive) {
    final size = isActive ? 26.0 : 24.0;
    final borderColor = isActive ? Colors.white : Colors.white54;
    final color = isActive ? Colors.white : Colors.white54;

    if (user?.photoURL != null) {
      return Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: borderColor, width: 2),
        ),
        child: CircleAvatar(
          radius: size / 2,
          backgroundImage: NetworkImage(user!.photoURL!),
        ),
      );
    }
    return Icon(
      isActive ? Icons.person_rounded : Icons.person_outline_rounded,
      size: size + 4,
      color: color,
    );
  }
}
