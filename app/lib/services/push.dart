import 'dart:developer' as dev;
import 'dart:io' show Platform;

import 'package:supabase_flutter/supabase_flutter.dart';

/// Push-token registration. The Supabase side (device_tokens table, own-row
/// RLS upsert) is LIVE; the FCM side is a seam awaiting Firebase config
/// (GoogleService-Info.plist + APNs key on a paid Apple Developer account —
/// the free personal team can't sign the aps-environment entitlement).
///
/// When Firebase lands: add firebase_core + firebase_messaging, then call
/// `PushService.register(await FirebaseMessaging.instance.getToken())` after
/// permission grant, and again inside `onTokenRefresh.listen`.
class PushService {
  PushService._();

  /// Upsert this device's FCM token for the signed-in user. Safe to call on
  /// every login/refresh — the token is the primary key.
  static Future<void> register(String? fcmToken) async {
    if (fcmToken == null || fcmToken.isEmpty) return;
    final sb = Supabase.instance.client;
    final uid = sb.auth.currentUser?.id;
    if (uid == null) return;
    try {
      await sb.from('device_tokens').upsert({
        'token': fcmToken,
        'user_id': uid,
        'platform': Platform.isIOS ? 'ios' : 'android',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      dev.log('push token upsert failed: $e', name: 'push');
    }
  }
}
