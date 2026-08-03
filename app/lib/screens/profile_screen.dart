import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../camera/guided_camera_screen.dart';
import '../providers.dart';
import '../services/auth.dart' as auth;
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import 'paywall_screen.dart';
import 'account_screen.dart';
import 'auth_screen.dart';
import 'dev_settings_screen.dart';
import 'onboarding_screen.dart';
import 'select_looks_screen.dart';
import 'wardrobe_items_screen.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _changingPhoto = false; // show a loader in the photo tile while updating

  Future<void> _openAccount({bool signIn = false}) async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AccountScreen(signIn: signIn)),
    );
    if (ok == true && mounted) setState(() {}); // refresh account card
  }

  /// DEV RESET (temporary): wipes ALL local state (SharedPreferences — onboarding
  /// flags, cached profile, signed-in flag, user id), signs out of Supabase, and
  /// hard-routes to the very first onboarding screen. Strip before release.
  Future<void> _devReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reset the app?'),
        content: const Text('Clears ALL local data and signs you out. You will restart onboarding from scratch.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Reset', style: TextStyle(color: AppColors.flag, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(profileStoreProvider).resetAll(); // full SharedPreferences wipe
    try {
      await auth.signOut(); // kill the Supabase session (token gone = tier gone)
    } catch (_) {}
    // Drop every cached provider (entitlement, body profile, …) — nothing may
    // survive into the fresh run.
    ref.invalidate(entitlementProvider);
    ref.invalidate(bodyProfileProvider);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthScreen()),
      (_) => false,
    );
  }

  Future<void> _signOut() async {
    await auth.signOut();
    ref.invalidate(bodyProfileProvider);
    ref.invalidate(entitlementProvider);
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AuthScreen()),
        (_) => false,
      );
    }
  }

  Future<void> _buildOrRemeasure() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const OnboardingScreen(skippable: true)));
    ref.invalidate(bodyProfileProvider);
  }

  /// Set/replace the default profile photo — reused across every flow (§14.11).
  Future<void> _changePhoto() async {
    if (!ref.read(cloudEnabledProvider)) {
      _snack('Photos sync in the cloud build.');
      return;
    }
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.bg,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined, color: AppColors.ink),
            title: const Text('Take a photo', style: TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined, color: AppColors.ink),
            title: const Text('Choose from gallery', style: TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (source == null || !mounted) return;
    final XFile? file;
    if (source == ImageSource.camera) {
      file = await Navigator.of(context).push<XFile?>(MaterialPageRoute(
          builder: (_) => const GuidedCameraScreen(config: GuidedCaptureConfig.body)));
    } else {
      file = await ImagePicker()
          .pickImage(source: ImageSource.gallery, maxWidth: 800, maxHeight: 800, imageQuality: 80);
    }
    if (file == null || !mounted) return;
    setState(() => _changingPhoto = true);
    try {
      await ref.read(looktokApiProvider).setBodyPhoto(await file.readAsBytes());
      ref.invalidate(bodyProfileProvider);
      if (mounted) _snack('Photo updated');
    } catch (_) {
      if (mounted) _snack('Couldn’t update photo');
    } finally {
      if (mounted) setState(() => _changingPhoto = false);
    }
  }

  /// Open the default photo full-screen (view your figure at full length).
  Future<void> _viewPhoto(String path) async {
    final url = await ref.read(looktokApiProvider).bodyPhotoUrl(path);
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, elevation: 0),
        body: Center(
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Image.network(url, fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Text('Could not load', style: TextStyle(color: Colors.white))),
          ),
        ),
      ),
    ));
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(bodyProfileProvider).valueOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('Your profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          _EntitlementBanner(entitlement: ref.watch(entitlementProvider)),
          const SizedBox(height: 12),
          _AccountCard(
            email: auth.currentEmail(),
            onCreate: () => _openAccount(signIn: false),
            onSignIn: () => _openAccount(signIn: true),
            onSignOut: _signOut,
          ),
          const SizedBox(height: 22),
          _PhotoCard(
            path: profile?['source_photo_path'] as String?,
            loading: _changingPhoto,
            onChange: _changePhoto,
            onView: _viewPhoto,
          ),
          const SizedBox(height: 12),
          _BodyProfileCard(row: profile, onAction: _buildOrRemeasure),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AppRadius.card),
              boxShadow: AppShadows.soft,
            ),
            child: ListTile(
              leading: const Icon(Icons.checkroom_outlined, color: AppColors.ink),
              title: const Text('My Wardrobe', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Clothes you own — used for “My clothes” looks'),
              trailing: const Icon(Icons.chevron_right, color: AppColors.muted),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const WardrobeItemsScreen())),
            ),
          ),
          const SizedBox(height: 12),
          // Style references: the user drops in looks they LOVE. These teach
          // the stylist their taste (reference_looks → style_dna) — far more
          // signal than the old free-text "styles/colors" fields, which fed
          // nothing. Reuses the onboarding SelectLooksScreen flow.
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AppRadius.card),
              boxShadow: AppShadows.soft,
            ),
            child: ListTile(
              leading: const Icon(Icons.auto_awesome_outlined, color: AppColors.ink),
              title: const Text('Style references', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Looks you love — we learn your taste from them'),
              trailing: const Icon(Icons.chevron_right, color: AppColors.muted),
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                final saved = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(builder: (_) => const SelectLooksScreen()));
                if (saved == true) {
                  messenger
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(content: Text('Style references saved')));
                }
              },
            ),
          ),
          const SizedBox(height: 28),
          // TEMP dev tool: full local wipe + backend sign-out + back to onboarding.
          // Strip before store release.
          Center(
            child: TextButton.icon(
              onPressed: _devReset,
              icon: const Icon(Icons.restart_alt, size: 16, color: AppColors.flag),
              label: const Text('Dev: Reset app',
                  style: TextStyle(color: AppColors.flag, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 4),
          // Secret latch: 7 taps on the version line (3s window) opens the
          // hidden Developer settings — invisible to normal users.
          Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _versionTap,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 10),
                child: Text('Looktok v1.0.0 (1)',
                    style: TextStyle(color: AppColors.muted, fontSize: 12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  int _versionTaps = 0;
  DateTime _lastVersionTap = DateTime.fromMillisecondsSinceEpoch(0);
  void _versionTap() {
    final now = DateTime.now();
    // Taps must be consecutive: a >3s pause restarts the count.
    _versionTaps = now.difference(_lastVersionTap) > const Duration(seconds: 3) ? 1 : _versionTaps + 1;
    _lastVersionTap = now;
    if (_versionTaps >= 7) {
      _versionTaps = 0;
      HapticFeedback.mediumImpact();
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DevSettingsScreen()));
    } else if (_versionTaps >= 4) {
      HapticFeedback.selectionClick(); // subtle "keep going" cue from tap 4
    }
  }

}

/// Fixed body params (locked once confirmed) + a re-measure action.
class _BodyProfileCard extends StatelessWidget {
  const _BodyProfileCard({required this.row, required this.onAction});
  final Map<String, dynamic>? row;
  final VoidCallback onAction;

  bool get _ready => row != null && row!['status'] == 'ready' && row!['height_cm'] != null;

  String? _range(String key) {
    final m = (row?['estimated_measurements'] as Map?)?[key] as Map?;
    final lo = m?['min'], hi = m?['max'];
    return (lo == null || hi == null) ? null : '${(lo as num).round()}–${(hi as num).round()} cm';
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.card),
          boxShadow: AppShadows.soft,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('No body profile yet', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 6),
            const Text('Add your height + a photo so the AI can factor in your build.',
                style: TextStyle(color: AppColors.muted, height: 1.4, fontSize: 13)),
            const SizedBox(height: 14),
            FilledButton(onPressed: onAction, child: const Text('Build body profile')),
          ],
        ),
      );
    }

    final height = (row!['height_cm'] as num?)?.round();
    final rows = <(String, String)>[
      if (height != null) ('Height', '$height cm'),
      if (_range('chest_cm') != null) ('Chest', _range('chest_cm')!),
      if (_range('waist_cm') != null) ('Waist', _range('waist_cm')!),
      if (_range('hip_cm') != null) ('Hip', _range('hip_cm')!),
      if (_range('inseam_cm') != null) ('Inseam', _range('inseam_cm')!),
    ];

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.straighten, size: 18, color: AppColors.ink),
              const SizedBox(width: 8),
              const Text('Body profile', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const Spacer(),
              const Text('Used by the AI', style: TextStyle(color: AppColors.muted, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 14),
          ...rows.map((r) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(r.$1, style: const TextStyle(color: AppColors.muted)),
                    Text(r.$2, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ),
              )),
          const SizedBox(height: 4),
          const Text('Estimates are approximate ranges from your photo.',
              style: TextStyle(color: AppColors.muted, fontSize: 12)),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Re-measure parameters'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Default photo — the selfie captured after sign-up, reused across every flow.
/// Shows the current photo with a Change action, or a prompt to add one (§14.11).
class _PhotoCard extends ConsumerWidget {
  const _PhotoCard({required this.path, required this.loading, required this.onChange, required this.onView});
  final String? path;
  final bool loading;
  final VoidCallback onChange;
  final void Function(String path) onView;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final has = path != null && path!.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.soft,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: (has && !loading) ? () => onView(path!) : null,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.control),
              child: SizedBox(
                width: 64,
                height: 84,
                child: Stack(fit: StackFit.expand, children: [
                  if (has)
                    FutureBuilder<String>(
                      future: ref.read(looktokApiProvider).bodyPhotoUrl(path!),
                      builder: (_, s) => s.hasData
                          ? Image.network(s.data!, fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const ColoredBox(color: AppColors.surface))
                          : const ColoredBox(color: AppColors.surface),
                    )
                  else
                    const ColoredBox(
                      color: AppColors.surface,
                      child: Icon(Icons.person_outline, color: AppColors.muted),
                    ),
                  // Loader while a new photo uploads/processes.
                  if (loading)
                    const ColoredBox(
                      color: Color(0xCC0A0A0A),
                      child: Center(
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                      ),
                    ),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Your photo', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                const SizedBox(height: 4),
                Text(
                  has ? 'Your default photo, used across your looks.' : 'Add a full-body photo to style your looks.',
                  style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.35),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: onChange,
                  icon: Icon(has ? Icons.cameraswitch_outlined : Icons.add_a_photo_outlined, size: 18),
                  label: Text(has ? 'Change photo' : 'Add photo'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Account card: guest → create/sign in; signed in → email + sign out.
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.email, required this.onCreate, required this.onSignIn, required this.onSignOut});
  final String? email;
  final VoidCallback onCreate;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final signedIn = email != null;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.soft,
      ),
      child: signedIn
          ? Row(children: [
              const Icon(Icons.account_circle_outlined, color: AppColors.ink),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Signed in', style: TextStyle(color: AppColors.muted, fontSize: 12)),
                  Text(email!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
              ),
              TextButton(onPressed: onSignOut, child: const Text('Sign out')),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Guest account', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 6),
              // Resolves the "Pro + guest" contradiction (P0-3): the plan and
              // data are real, but device-bound until an account exists.
              const Text(
                'Your looks, wardrobe and plan live only on this device. Create an account to keep them.',
                style: TextStyle(color: AppColors.muted, height: 1.4, fontSize: 13),
              ),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(child: FilledButton(onPressed: onCreate, child: const Text('Create account'))),
                const SizedBox(width: 12),
                Expanded(child: OutlinedButton(onPressed: onSignIn, child: const Text('Sign in'))),
              ]),
            ]),
    );
  }
}

/// Subscription card: balance + plan management in one place. Free → the
/// paywall (upgrade / promo code); Pro → Apple's subscription management.
class _EntitlementBanner extends StatelessWidget {
  const _EntitlementBanner({required this.entitlement});
  final AsyncValue<Map<String, dynamic>> entitlement;

  @override
  Widget build(BuildContext context) {
    final pro = entitlement.valueOrNull?['pro'] == true;
    final (label, sub) = switch (entitlement) {
      AsyncData(:final value) when value['pro'] == true => ('Pro', 'Unlimited reviews & looks'),
      AsyncData(:final value) => ('${value['freeRemaining'] ?? 0} free left', 'Reviews & looks remaining'),
      AsyncError() => ('—', 'Balance unavailable'),
      _ => ('…', 'Loading balance'),
    };
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(18)),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome, color: AppColors.signature, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18)),
                Text(sub, style: const TextStyle(color: Color(0xFFAAAAA6), fontSize: 13)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: pro ? Colors.white12 : AppColors.signature,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              if (pro) {
                // Apple owns the subscription lifecycle — deep-link to it.
                launchUrl(Uri.parse('https://apps.apple.com/account/subscriptions'),
                    mode: LaunchMode.externalApplication);
              } else {
                Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PaywallScreen()));
              }
            },
            child: Text(pro ? 'Manage' : 'Go Pro',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
