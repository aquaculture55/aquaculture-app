// lib/pages/trends_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

class TrendsPage extends StatefulWidget {
  final TabController tabController;
  final List<String> sensors;
  final String deviceId;

  const TrendsPage({
    super.key,
    required this.tabController,
    required this.sensors,
    required this.deviceId,
  });

  @override
  State<TrendsPage> createState() => _TrendsPageState();
}

class _TrendsPageState extends State<TrendsPage> {
  Stream<Map<String, Map<String, double>>> _thresholdsStream() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || widget.deviceId.isEmpty) return const Stream.empty();

    return FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('thresholds')
        .doc(widget.deviceId)
        .snapshots()
        .map((doc) {
          final thresholds = <String, Map<String, double>>{};
          if (!doc.exists) return thresholds;

          final data = doc.data() ?? {};
          for (final sensor in widget.sensors) {
            final m = data[sensor];
            if (m is Map<String, dynamic>) {
              thresholds[sensor] = {
                'min': _toDouble(m['min']),
                'max': _toDouble(m['max']),
              };
            }
          }
          return thresholds;
        });
  }

  static double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? double.nan;
    return double.nan;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.deviceId.isEmpty) {
      return const Center(child: Text('Please select a device to view trends'));
    }

    return StreamBuilder<Map<String, Map<String, double>>>(
      stream: _thresholdsStream(),
      builder: (context, snapshot) {
        final thresholds = snapshot.data ?? const {};

        return TabBarView(
          controller: widget.tabController,
          children: widget.sensors.map((sensor) {
            return SensorChart(
              key: ValueKey('${widget.deviceId}_$sensor'),
              deviceId: widget.deviceId,
              sensorType: sensor,
              thresholds: thresholds,
              tabController: widget.tabController,
            );
          }).toList(),
        );
      },
    );
  }
}

class SensorChart extends StatefulWidget {
  final String deviceId;
  final String sensorType;
  final Map<String, Map<String, double>> thresholds;
  final TabController tabController;

  const SensorChart({
    super.key,
    required this.deviceId,
    required this.sensorType,
    required this.thresholds,
    required this.tabController,
  });

  @override
  State<SensorChart> createState() => _SensorChartState();
}

class _SensorChartState extends State<SensorChart>
    with AutomaticKeepAliveClientMixin {
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subscription;
  List<_Pt> chartData = [];

  // --- NEW: Interactive Behaviors ---
  late TrackballBehavior _trackballBehavior;
  late ZoomPanBehavior _zoomPanBehavior;

  @override
  void initState() {
    super.initState();

    // 1. Initialize Trackball (Slide finger to see values)
    _trackballBehavior = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap, // Tap or drag to activate
      tooltipSettings: const InteractiveTooltip(
        enable: true,
        color: Colors.black87,
        format: 'point.y', // Shows value in tooltip
      ),
      // Shows a line and marker where you touch
      lineType: TrackballLineType.vertical,
      markerSettings: const TrackballMarkerSettings(
        markerVisibility: TrackballVisibilityMode.visible,
      ),
      shouldAlwaysShow: true, // Snaps to nearest point
    );

    // 2. Initialize Zoom (Pinch to zoom)
    _zoomPanBehavior = ZoomPanBehavior(
      enablePinching: true,
      enablePanning: true,
      enableDoubleTapZooming: true,
      zoomMode: ZoomMode.x, // Zooming time usually makes more sense
    );

    _subscribeToReadings();
  }

  void _subscribeToReadings() {
    _subscription?.cancel();
    if (widget.deviceId.isEmpty) return;

    _subscription = FirebaseFirestore.instance
        .collection('readings')
        .doc(widget.deviceId)
        .collection('data')
        .orderBy('timestamp', descending: false)
        .limit(500)
        .snapshots()
        .listen(
          _processReadings,
          onError: (e) => debugPrint('❌ Trends stream error: $e'),
        );
  }

  void _processReadings(QuerySnapshot<Map<String, dynamic>> snapshot) {
    final points = <_Pt>[];

    for (final doc in snapshot.docs) {
      final data = doc.data();
      final rawVal = data[widget.sensorType];
      final rawTs = data['timestamp'];
      if (rawVal == null || rawTs == null) continue;

      final value = (rawVal is num)
          ? rawVal.toDouble()
          : double.tryParse(rawVal.toString());
      if (value == null) continue;

      final time = (rawTs is Timestamp)
          ? rawTs.toDate()
          : (rawTs is int ? DateTime.fromMillisecondsSinceEpoch(rawTs) : null);
      if (time == null) continue;

      points.add(_Pt(time: time, value: value));
    }

    // Increased downsample limit slightly to keep more detail
    setState(() => chartData = downsample(points, 200));
  }

  List<_Pt> downsample(List<_Pt> data, int maxPoints) {
    if (data.length <= maxPoints) return data;
    final step = (data.length / maxPoints).ceil();
    return [for (var i = 0; i < data.length; i += step) data[i]];
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (chartData.isEmpty) {
      return const Center(child: Text('No sensor data available'));
    }

    final minTh = widget.thresholds[widget.sensorType]?['min'];
    final maxTh = widget.thresholds[widget.sensorType]?['max'];
    final latest = chartData.last;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with latest reading
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.sensorType.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        "Latest: ${latest.value.toStringAsFixed(2)}",
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        DateFormat("MMM d, HH:mm").format(latest.time),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SfCartesianChart(
                  // 3. Attach Behaviors
                  trackballBehavior: _trackballBehavior,
                  zoomPanBehavior: _zoomPanBehavior,

                  primaryXAxis: DateTimeAxis(
                    dateFormat: DateFormat('HH:mm'),
                    intervalType: DateTimeIntervalType.hours,
                    edgeLabelPlacement: EdgeLabelPlacement.shift,
                    majorGridLines: const MajorGridLines(
                      width: 0,
                    ), // Cleaner look
                  ),
                  primaryYAxis: NumericAxis(
                    axisLine: const AxisLine(width: 0),
                    majorTickLines: const MajorTickLines(size: 0),
                    plotBands: [
                      if (minTh != null)
                        _buildPlotBand(minTh, Colors.green, 'Min $minTh'),
                      if (maxTh != null)
                        _buildPlotBand(maxTh, Colors.red, 'Max $maxTh'),
                    ],
                  ),

                  // NOTE: TooltipBehavior removed because Trackball replaces it
                  series: <CartesianSeries<_Pt, DateTime>>[
                    LineSeries<_Pt, DateTime>(
                      name: widget.sensorType.toUpperCase(),
                      dataSource: chartData,
                      xValueMapper: (d, _) => d.time,
                      yValueMapper: (d, _) => d.value,
                      animationDuration: 600,

                      // 4. Thicker Line & Visible Markers
                      width: 3, // Thicker line is easier to see
                      color: Colors.blueAccent,
                      markerSettings: const MarkerSettings(
                        isVisible: true, // ✅ ALWAYS show dots
                        height: 6, // Small dots so they don't clutter
                        width: 6,
                        shape: DataMarkerType.circle,
                        borderWidth: 0,
                        color: Color.fromARGB(255, 8, 228, 132),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  PlotBand _buildPlotBand(double value, Color color, String label) {
    return PlotBand(
      start: value - 0.001,
      end: value + 0.001,
      borderColor: color.withOpacity(0.5),
      borderWidth: 1.5,
      // dashArray: const <double>[5, 5], // Optional: Dashed line for thresholds
      text: label,
      textStyle: TextStyle(
        fontSize: 11,
        color: color,
        fontWeight: FontWeight.w600,
      ),
      horizontalTextAlignment: TextAnchor.end,
      verticalTextAlignment: TextAnchor.start,
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class _Pt {
  final DateTime time;
  final double value;
  final String displayTime;
  final String displayValue;

  _Pt({required DateTime? time, required double? value})
    : time = time ?? DateTime.now(),
      value = value ?? 0.0,
      displayTime = DateFormat('MMM d, HH:mm').format(time ?? DateTime.now()),
      displayValue = (value ?? 0.0).toStringAsFixed(2);
}
