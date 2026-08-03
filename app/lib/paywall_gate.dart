import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'screens/paywall_screen.dart';

/// Token interceptor (SDD §8). Returns true if the action may proceed (pro or
/// free reviews remaining); otherwise presents the paywall and returns false.
/// FAIL CLOSED: a missing/expired session or an unreadable entitlement demotes
/// to zero access — it must never silently grant the unlimited tier (the old
/// `?? 10` default did exactly that when the provider hadn't loaded).
Future<bool> ensureTokens(BuildContext context, WidgetRef ref) async {
  Map<String, dynamic>? ent;
  try {
    ent = await ref.read(entitlementProvider.future); // resolves, not a stale .value peek
  } catch (_) {
    ent = null; // no session / backend unreachable → locked, not unlimited
  }
  final pro = ent?['pro'] == true;
  final left = (ent?['freeRemaining'] is int) ? ent!['freeRemaining'] as int : 0;
  if (pro || left > 0) return true;
  if (!context.mounted) return false;
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const PaywallScreen()),
  );
  return false;
}
