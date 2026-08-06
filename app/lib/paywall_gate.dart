import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'screens/paywall_screen.dart';

/// How long the balance check may take before the tap gets an answer anyway.
///
/// A TAP MUST ALWAYS PRODUCE SOMETHING. Without this the gate awaited the
/// entitlement provider with no bound, so an unresolved request — no session yet,
/// a cold Edge Function, a phone that changed networks mid-flight — left the await
/// pending forever. The handler never reached its next line, nothing was shown,
/// and the button read as broken ("не нажимается"). It was not: it was waiting.
/// Six seconds is well past a warm round trip and well inside the patience of
/// somebody who just pressed a button.
const _kBalanceTimeout = Duration(seconds: 6);

/// Token interceptor (SDD §8). Returns true if the action may proceed (pro or
/// free reviews remaining); otherwise presents the paywall and returns false.
/// FAIL CLOSED: a missing/expired session or an unreadable entitlement demotes
/// to zero access — it must never silently grant the unlimited tier (the old
/// `?? 10` default did exactly that when the provider hadn't loaded).
Future<bool> ensureTokens(BuildContext context, WidgetRef ref) async {
  Map<String, dynamic>? ent;
  Object? failure;
  try {
    // resolves, not a stale .value peek — but bounded, see _kBalanceTimeout
    ent = await ref.read(entitlementProvider.future).timeout(_kBalanceTimeout);
  } catch (e) {
    failure = e; // no session / backend unreachable / timed out → locked
    ent = null;
  }
  final pro = ent?['pro'] == true;
  final left = (ent?['freeRemaining'] is int) ? ent!['freeRemaining'] as int : 0;
  if (pro || left > 0) return true;
  if (!context.mounted) return false;

  // "OUT OF TOKENS" AND "COULD NOT TELL" ARE DIFFERENT ANSWERS, and only one of
  // them is a reason to show the paywall. Sending someone to buy tokens because
  // their connection dropped is a lie about their account; showing nothing at all
  // is worse. Both stay locked — the fail-closed rule is not negotiable — but the
  // failure says so out loud and offers the retry, which is the whole difference
  // between a broken button and a slow one.
  if (failure != null) {
    final timedOut = failure is TimeoutException;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(timedOut
          ? "Couldn't check your balance — the connection timed out."
          : "Couldn't check your balance. Sign in again and retry."),
      action: SnackBarAction(
        label: 'Retry',
        onPressed: () => ref.invalidate(entitlementProvider),
      ),
      duration: const Duration(seconds: 5),
    ));
    return false;
  }

  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const PaywallScreen()),
  );
  return false;
}
