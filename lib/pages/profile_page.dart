import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:aquaculture/authentication/auth_service.dart';
import 'package:provider/provider.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  Future<void> _signOut() async {
    final authService = context.read<AuthService>();
    await authService.signOut();
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text("Sign Out", textAlign: TextAlign.center),
        content: const Text("Are you sure you want to sign out?", textAlign: TextAlign.center),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
              minimumSize: const Size(80, 36),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Sign Out", style: TextStyle(fontSize: 14,color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) _signOut();
  }

  String _formatTimestamp(DateTime? dt) {
    if (dt == null) return "Unknown";
    return DateFormat('MMM dd, yyyy - hh:mm a').format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;

    if (currentUser == null) {
      return const Scaffold(body: Center(child: Text("No user logged in")));
    }

    return Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Compact Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 40),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF1E3A8A), Color(0xFF2563EB), Color(0xFF60A5FA)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.only(bottomLeft: Radius.circular(20), bottomRight: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 40,
                    backgroundImage: currentUser.photoURL != null ? NetworkImage(currentUser.photoURL!) : null,
                    child: currentUser.photoURL == null ? const Icon(Icons.person, size: 40, color: Colors.white) : null,
                  ),
                  const SizedBox(height: 10),
                  Text(currentUser.displayName ?? "Anonymous User",
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(height: 2),
                  Text(currentUser.email ?? "", style: const TextStyle(fontSize: 14, color: Colors.white70)),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // Info cards
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  _infoCard(Icons.person_outline, "UID", currentUser.uid),
                  const SizedBox(height: 6),
                  _infoCard(Icons.calendar_today, "Account Created",
                      _formatTimestamp(currentUser.metadata.creationTime)),
                  const SizedBox(height: 6),
                  _infoCard(Icons.access_time, "Last Sign-In",
                      _formatTimestamp(currentUser.metadata.lastSignInTime)),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Sign Out Button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _confirmSignOut,
                  child: const Text("Sign Out", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ),
            ),

            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _infoCard(IconData icon, String title, String value) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 24, color: const Color.fromARGB(255, 78, 109, 163)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  const SizedBox(height: 2),
                  Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
