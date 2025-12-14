import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../notification/alerts_service.dart';
import 'package:intl/intl.dart';

class AlertsPage extends StatelessWidget {
  final String deviceId;

  const AlertsPage({super.key, required this.deviceId});

  Future<void> _deleteAlert(BuildContext context, String alertId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || deviceId.isEmpty) return;

    try {
      await AlertsService().deleteAlert(user.uid, deviceId, alertId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Alert deleted')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete alert: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return const Center(child: Text('Please log in'));
    }

    if (deviceId.isEmpty) {
      return const Center(child: Text('No device selected'));
    }

    final alertsStream = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('alerts')
        .doc(deviceId)
        .collection('logs')
        .orderBy('timestamp', descending: true)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: alertsStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(child: Text('Error loading alerts: ${snapshot.error}'));
        }

        final alerts = snapshot.data?.docs ?? [];
        if (alerts.isEmpty) {
          return const Center(child: Text('No alerts yet'));
        }

        return ListView.separated(
          padding: const EdgeInsets.all(8),
          itemCount: alerts.length,
          separatorBuilder: (_, __) => const SizedBox(height: 6),
          itemBuilder: (context, index) {
            final doc = alerts[index];
            final data = doc.data();
            final ts = data['timestamp'];
            final when = ts is Timestamp
                ? ts.toDate()
                : ts is int
                    ? DateTime.fromMillisecondsSinceEpoch(ts)
                    : null;

            // Determine severity color
            final isHigh = (data['severity'] ?? '').toString().toLowerCase() == 'high';
            final cardColor = isHigh ? Colors.red.shade50 : Colors.orange.shade50;
            final iconColor = isHigh ? Colors.red : Colors.orange;

            return Dismissible(
              key: Key(doc.id),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                color: Colors.red,
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              onDismissed: (_) => _deleteAlert(context, doc.id),
              child: Card(
                color: cardColor,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  leading: CircleAvatar(
                    backgroundColor: iconColor.withOpacity(0.2),
                    child: Icon(Icons.warning, color: iconColor),
                  ),
                  title: Text(
                    data['title'] ?? 'No Title',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if ((data['message'] ?? '').isNotEmpty)
                        Text(
                          data['message'] ?? '',
                          style: const TextStyle(fontSize: 13),
                        ),
                      if (when != null)
                        Text(
                          DateFormat('MMM d, yyyy – HH:mm').format(when),
                          style: const TextStyle(fontSize: 11, color: Colors.black54),
                        ),
                    ],
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => _deleteAlert(context, doc.id),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
