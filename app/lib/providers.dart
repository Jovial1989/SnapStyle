import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/profile.dart';
import 'services/api_client.dart';
import 'services/auth.dart' as auth;
import 'services/feature_flags.dart';
import 'services/profile_store.dart';
import 'services/smart_image_processing.dart';
import 'services/looktok_api.dart';

/// Overridden in main() once SharedPreferences is ready.
final profileStoreProvider = Provider<ProfileStore>(
  (ref) => throw UnimplementedError('profileStoreProvider must be overridden'),
);

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

/// Cloud client (Supabase Edge Functions). Used when [cloudEnabledProvider] is true.
final looktokApiProvider = Provider<LooktokApi>((ref) => LooktokApi());

/// Remote feature flags (Supabase) + dev overrides — cached, never throws.
final featureFlagServiceProvider =
    Provider<FeatureFlagService>((ref) => FeatureFlagService());

/// Unified image pipeline: silhouette isolation → the right Edge Function.
/// Front door for review/compare/wardrobe photo flows. The SAM 2 experimental
/// engine is gated by the `use_sam2_engine` flag (or the hidden dev override).
final smartImageProcessingProvider =
    Provider<SmartImageProcessingService>((ref) => SmartImageProcessingService(
          ref.watch(looktokApiProvider),
          sam2Gate: ref.watch(featureFlagServiceProvider).useSam2Engine,
        ));

/// True when the app was built with Supabase config → route AI calls to the cloud.
final cloudEnabledProvider = Provider<bool>((ref) => auth.cloudReady());

final appUserIdProvider = Provider<String>(
  (ref) => ref.watch(profileStoreProvider).appUserId(),
);

/// Editable profile, persisted on every change.
class ProfileNotifier extends Notifier<StyleProfile> {
  @override
  StyleProfile build() => ref.watch(profileStoreProvider).load();

  Future<void> update(StyleProfile p) async {
    state = p;
    await ref.read(profileStoreProvider).save(p);
  }
}

final profileProvider =
    NotifierProvider<ProfileNotifier, StyleProfile>(ProfileNotifier.new);

/// The user's confirmed body profile row (cloud), or null. Drives: hiding the
/// "build profile" card once done, and showing fixed params in Profile.
final bodyProfileProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  if (!ref.watch(cloudEnabledProvider)) return null;
  return ref.watch(looktokApiProvider).bodyProfile();
});

/// Most recent scanned-outfit image URL — powers the home "Frosted Canvas".
final recentScanUrlProvider = FutureProvider<String?>((ref) async {
  if (!ref.watch(cloudEnabledProvider)) return null;
  return ref.watch(looktokApiProvider).recentScanUrl();
});

/// True once a body profile is built + confirmed.
final hasBodyProfileProvider = Provider<bool>((ref) {
  final row = ref.watch(bodyProfileProvider).valueOrNull;
  return row != null && row['status'] == 'ready' && row['height_cm'] != null;
});

/// Server-authoritative entitlement + free-analysis balance (SDD §8.2).
/// Cloud → read own `entitlements` row (owner RLS); local → Node dev server.
final entitlementProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  if (ref.watch(cloudEnabledProvider)) {
    // No live session = no tier. Locked result instead of a null-deref throw
    // (which callers used to swallow and misread as "unlimited").
    if (!auth.hasSession()) return {'pro': false, 'freeRemaining': 0};
    return ref.watch(looktokApiProvider).entitlement();
  }
  final api = ref.watch(apiClientProvider);
  final id = ref.watch(appUserIdProvider);
  return api.entitlement(id);
});
