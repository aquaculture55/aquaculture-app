import 'package:cloud_firestore/cloud_firestore.dart';

class AlertsRepository {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<DocumentReference> addAlert({
    required String uid,
    required String deviceId,
    required String title,
    required String message,
    required String sensor,
    dynamic value,
    Map<String, dynamic>? readings,
  }) async {
    final docRef = await _firestore
        .collection('users')
        .doc(uid)
        .collection('devices')
        .doc(deviceId)
        .collection('alerts')
        .add({
      'title': title,
      'message': message,
      'sensor': sensor,
      'value': value,
      'readings': readings,
      'timestamp': FieldValue.serverTimestamp(),
      'notified': false,
    });

    return docRef;
  }
}
