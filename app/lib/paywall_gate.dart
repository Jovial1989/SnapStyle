import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'screens/paywall_screen.dart';

/// Token interceptor (SDD §8). Returns true if the action may proceed (pro or
/// free reviews remaining); otherwise presents the paywall and returns false.
/// Wrap the camera button and occasion chips with this.
Future<bool> ensureTokens(BuildContext context, WidgetRef ref) async {
  final ent = ref.read(entitlementProvider).value;
  final pro = ent?['pro'] == true;
  final left = (ent?['freeRemaining'] is int) ? ent!['freeRemaining'] as int : 10;
  if (pro || left > 0) return true;
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const PaywallScreen()),
  );
  return false;
}
