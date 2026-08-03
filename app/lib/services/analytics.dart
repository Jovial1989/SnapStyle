import 'dart:developer' as dev;

import 'package:amplitude_flutter/amplitude.dart';
import 'package:amplitude_flutter/configuration.dart';
import 'package:amplitude_flutter/events/base_event.dart';
import 'package:amplitude_flutter/events/identify.dart';

/// Product analytics façade (Amplitude). The core-funnel taxonomy lives HERE
/// and only here — screens call the named methods, never raw strings, so the
/// event names/props can't drift between call sites.
///
/// Fails soft by design: no AMPLITUDE_API_KEY compiled in (dev builds) → every
/// call is a debug log no-op. Analytics must never crash or block the product.
class Analytics {
  Analytics._();

  static const _apiKey = String.fromEnvironment('AMPLITUDE_API_KEY');
  static Amplitude? _amp;
  static bool get enabled => _amp != null;

  static Future<void> init() async {
    if (_apiKey.isEmpty) {
      dev.log('Analytics disabled (no AMPLITUDE_API_KEY)', name: 'analytics');
      return;
    }
    try {
      final amp = Amplitude(Configuration(apiKey: _apiKey));
      await amp.isBuilt;
      _amp = amp;
    } catch (e) {
      dev.log('Amplitude init failed: $e', name: 'analytics');
    }
  }

  /// Identify by the Supabase auth uid — an opaque UUID, never email/PII.
  static void setUserId(String? uid) {
    try {
      _amp?.setUserId(uid);
      if (uid != null) _amp?.identify(Identify()..set('platform', 'ios'));
    } catch (_) {}
  }

  static void _track(String name, [Map<String, Object?> props = const {}]) {
    if (_amp == null) {
      dev.log('$name $props', name: 'analytics');
      return;
    }
    try {
      _amp!.track(BaseEvent(name, eventProperties: Map.of(props)));
    } catch (_) {}
  }

  // ── Core funnel taxonomy ──────────────────────────────────────────────────
  static void avatarUploaded({required bool success}) =>
      _track('Avatar_Uploaded', {'success': success});
  static void generationStarted({required String tier}) =>
      _track('Generation_Started', {'tier': tier});
  static void generationCompleted({required int latencyMs}) =>
      _track('Generation_Completed', {'latency_ms': latencyMs});
  static void premiumFeatureTapped(String featureName) =>
      _track('Premium_Feature_Tapped', {'feature_name': featureName});
  static void paywallViewed() => _track('Paywall_Viewed');
  static void subscriptionPurchased({required String plan, required double revenue}) =>
      _track('Subscription_Purchased', {'plan': plan, 'revenue': revenue});
  static void promoRedeemed({required String code}) =>
      _track('Promo_Redeemed', {'code': code});
}
