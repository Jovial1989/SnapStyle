import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'screens/onboarding_screen.dart';

/// Body-profile interceptor. A confirmed body profile is REQUIRED before any
/// measure/assess/look flow (SDD §14). Returns true if the action may proceed;
/// otherwise routes into the (mandatory) builder and returns whether it's now built.
/// No-op (true) in the local dev build where there's no cloud profile store.
Future<bool> ensureBodyProfile(BuildContext context, WidgetRef ref) async {
  if (!ref.read(cloudEnabledProvider)) return true;
  final api = ref.read(looktokApiProvider);
  if (await api.hasBodyProfile()) return true;
  if (!context.mounted) return false;

  final built = await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => const OnboardingScreen(skippable: false)),
  );
  if (built == true) return true;
  // Fall back to a fresh check in case it was built then popped without a result.
  return api.hasBodyProfile();
}
