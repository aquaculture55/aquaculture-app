import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ControlController extends ChangeNotifier {
  // --- CONFIGURATION ---
  static const int kLampCooldownSeconds = 5;
  static const int kSleepDurationSeconds = 5 * 60; // 15 Minutes
  static const int kGreenStatusDurationSeconds = 15; // 2 hours for Demo, but 6hours in production

  // --- STATE VARIABLES ---
  DateTime? lastFeederPressTime;
  DateTime? lastLampPressTime;
  
  DateTime? lastFeederConfirmedTime;
  DateTime? lastLampConfirmedTime;

  Timer? _uiRefreshTimer;

  // Error messaging (Not used in this simple mode, but kept for compatibility)
  String? _uiMessage; 
  String? get uiMessage => _uiMessage;

  void clearMessage() { _uiMessage = null; }

  // --- INIT & DISPOSE ---
  void init(String deviceId) {
    _loadSavedTimestamps(deviceId);
    
    // REFRESH TIMER: Updates the countdown every second
    _uiRefreshTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _uiRefreshTimer?.cancel();
    super.dispose();
  }

  // --- PERSISTENCE ---
  Future<void> _loadSavedTimestamps(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    
    // 1. Load "Confirmed" times (Real feedback from device)
    final feedConf = prefs.getInt('last_feed_confirmed_$deviceId');
    final lampConf = prefs.getInt('last_lamp_confirmed_$deviceId');

    if (feedConf != null) lastFeederConfirmedTime = DateTime.fromMillisecondsSinceEpoch(feedConf);
    if (lampConf != null) lastLampConfirmedTime = DateTime.fromMillisecondsSinceEpoch(lampConf);
    
    // 2. FORCE RESET STUCK BUTTONS (The Fix for "Gray Button")
    // We do NOT load 'last_feed_press_' or 'last_lamp_press_' here.
    // This ensures that if you restart the app, the "Connecting..." state is gone.
    // We also explicitly remove them from storage to be clean.
    await prefs.remove('last_feed_press_$deviceId');
    await prefs.remove('last_lamp_press_$deviceId');
    lastFeederPressTime = null;
    lastLampPressTime = null;

    notifyListeners();
  }

  Future<void> _saveTime(String deviceId, String type, String kind, DateTime? time) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'last_${type}_${kind}_$deviceId';
    if (time == null) {
      await prefs.remove(key);
    } else {
      await prefs.setInt(key, time.millisecondsSinceEpoch);
    }
  }

  // --- SYNC LOGIC (Updates "Confirmed" time when MQTT data arrives) ---
  void syncFeederTime(String deviceId, DateTime? externalTime) {
    if (externalTime != null) {
      if (lastFeederConfirmedTime == null || externalTime.isAfter(lastFeederConfirmedTime!)) {
        lastFeederConfirmedTime = externalTime;
        _saveTime(deviceId, 'feed', 'confirmed', externalTime);
        notifyListeners(); 
      }
    }
  }

  void syncLampTime(String deviceId, DateTime? externalTime) {
    if (externalTime != null) {
      if (lastLampConfirmedTime == null || externalTime.isAfter(lastLampConfirmedTime!)) {
        lastLampConfirmedTime = externalTime;
        _saveTime(deviceId, 'lamp', 'confirmed', externalTime);
        notifyListeners();
      }
    }
  }

  // --- USER ACTIONS (FIRE AND FORGET MODE) ---
  
  // 1. FEEDER ACTION
  Future<void> handleFeederPress(String deviceId) async {
    final now = DateTime.now();
    lastFeederPressTime = now; 
    
    // Save to disk so cooldown persists even if you close app (optional, usually good)
    _saveTime(deviceId, 'feed', 'press', now);
    
    notifyListeners();
    // No "_checkTransactionStatus" call here. Just send and assume success.
  }

  // 2. LAMP ACTION
  Future<void> handleLampPress(String deviceId) async {
    final now = DateTime.now();
    lastLampPressTime = now;
    _saveTime(deviceId, 'lamp', 'press', now);
    notifyListeners();
  }

  // --- UI STATE GETTERS ---

  DateTime? _getLatestActionTime(DateTime? local, DateTime? confirmed) {
    if (local == null) return confirmed;
    if (confirmed == null) return local;
    return local.isAfter(confirmed) ? local : confirmed;
  }

  // FEEDER STATE
  bool get isFeederCooling {
    final latest = _getLatestActionTime(lastFeederPressTime, lastFeederConfirmedTime);
    if (latest == null) return false;
    return DateTime.now().difference(latest).inSeconds < kSleepDurationSeconds;
  }

  // SIMPLIFIED: Never stuck in syncing
  bool get isFeederSyncing => false; 

  String get feederButtonText {
    // No "Connecting..." check
    if (isFeederCooling) {
      final latest = _getLatestActionTime(lastFeederPressTime, lastFeederConfirmedTime);
      int remaining = kSleepDurationSeconds - DateTime.now().difference(latest!).inSeconds;
      return "Wait ${_formatCountdown(remaining)}";
    }
    return "Feed Now";
  }

  String get feederLastUpdatedText => "Last Fed: ${_formatTime(lastFeederConfirmedTime)}";
  
  bool get isRecentlyFed {
    if (lastFeederConfirmedTime == null) return false;
    final diff = DateTime.now().difference(lastFeederConfirmedTime!).inSeconds;
    return diff < kGreenStatusDurationSeconds;
  }

  String get feederStatusLabel => isRecentlyFed ? "FED" : "READY";

  // LAMP STATE
  bool get isLampCooling {
    final latest = _getLatestActionTime(lastLampPressTime, lastLampConfirmedTime);
    if (latest == null) return false;
    return DateTime.now().difference(latest).inSeconds < kLampCooldownSeconds; 
  }

  // SIMPLIFIED: Never stuck in syncing
  bool get isLampSyncing => false;

  String getLampButtonText(bool isOn) {
    if (isLampCooling) {
       final latest = _getLatestActionTime(lastLampPressTime, lastLampConfirmedTime);
       int remaining = kLampCooldownSeconds - DateTime.now().difference(latest!).inSeconds;
       return "${_formatCountdown(remaining)}";
    }
    return "Turn ${isOn ? 'OFF' : 'ON'}";
  }
  
  String get lampLastUpdatedText => "Last Toggled: ${_formatTime(lastLampConfirmedTime)}";

  // --- FORMATTING ---
  String _formatCountdown(int totalSeconds) {
    if (totalSeconds < 0) return "00:00";
    final int minutes = totalSeconds ~/ 60;
    final int seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return "--:--";
    return DateFormat('MMM d, h:mm a').format(dt);
  }
}