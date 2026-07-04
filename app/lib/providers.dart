import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/profile.dart';
import 'services/api_client.dart';
import 'services/profile_store.dart';

/// Overridden in main() once SharedPreferences is ready.
final profileStoreProvider = Provider<ProfileStore>(
  (ref) => throw UnimplementedError('profileStoreProvider must be overridden'),
);

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

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

/// Server-authoritative entitlement + free-analysis balance (SDD §8.2).
final entitlementProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final id = ref.watch(appUserIdProvider);
  return api.entitlement(id);
});
