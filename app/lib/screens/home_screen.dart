import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../body_profile_gate.dart';
import '../camera/guided_camera_screen.dart';
import '../paywall_gate.dart';
import '../models/subject.dart';
import '../providers.dart';
import '../services/analytics.dart';
import '../services/smart_image_processing.dart';
import '../services/looktok_api.dart';
import '../theme.dart';
import '../services/photo_validator.dart';
import '../widgets/global_loader_overlay.dart';
import '../widgets/stylist_portal.dart';
import '../widgets/subject_sheet.dart';
import '../widgets/wordmark.dart';
import 'compare_looks_screen.dart';
import 'look_editor_screen.dart';
import 'look_gen_screen.dart';
import 'atelier3d_screen.dart';
import 'wardrobe_items_screen.dart';
import '../widgets/looktok_action_card.dart';

// In-house 3D engine prototype entry (beta).
const bool _k3dAtelier = false;

class HomeTab extends ConsumerStatefulWidget {
  const HomeTab({super.key});
  @override
  ConsumerState<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends ConsumerState<HomeTab> {
  // ── Fit Check: gate tokens → pick a photo → ask whose look it is → analyze ──
  Future<void> _startReview() async {
    if (!await ensureTokens(context, ref)) return;
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.bg,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetTile(icon: Icons.camera_alt_outlined, label: 'Take a photo', onTap: () { Navigator.pop(context); _fromCamera(); }),
            _SheetTile(icon: Icons.photo_library_outlined, label: 'Choose from gallery', onTap: () { Navigator.pop(context); _fromGallery(); }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── "What should I wear?" → unified Stylist Portal (Journey B) ──
  Future<void> _openStylist() async {
    final recent = ref.read(profileStoreProvider).recentOccasions();
    final res = await openStylistPortal(context,
        recent: recent,
        wardrobeCount: ref.read(looktokApiProvider).wardrobeCount());
    if (res == null || !mounted) return;
    if (res.digitize) {
      // Wardrobe source picked with a near-empty closet — the portal turned
      // into the "digitize your wardrobe" action.
      Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const WardrobeItemsScreen()));
      return;
    }
    ref.read(profileStoreProvider).addRecentOccasion(res.text);
    _runWardrobe(res.text, photo: res.photo, closet: res.closet);
  }

  Future<void> _runWardrobe(String occasion, {XFile? photo, bool closet = false}) async {
    // Whose look? Guests are only possible when a photo of them is supplied
    // (styling the owner's stored body photo is always "me").
    var subject = const Subject.me();
    Uint8List? photoBytes;
    if (photo != null) {
      photoBytes = await photo.readAsBytes();
      if (!mounted) return;
      final s = await askSubject(context, ref, photoBytes: photoBytes);
      if (s == null || !mounted) return;
      subject = s;
    }
    if (subject.isMe) {
      if (!await ensureBodyProfile(context, ref)) return;
      if (!mounted) return;
    }
    if (!ref.read(cloudEnabledProvider)) {
      _snack('Look generation needs the cloud build.');
      return;
    }
    final api = ref.read(looktokApiProvider);
    if (closet && (await api.wardrobeItems()).isEmpty) {
      if (!mounted) return;
      _snack('Add clothes to your wardrobe first.');
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WardrobeItemsScreen()));
      return;
    }
    if (!mounted) return;
    if (!await ensureTokens(context, ref)) return;

    String? photoPath;
    if (photoBytes != null) {
      photoPath = await api.uploadPhoto(photoBytes);
    } else {
      photoPath = await _ensureBodyPhoto(api);
    }
    if (photoPath == null || !mounted) return;
    final path = photoPath;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LookGenScreen(
            photoPath: path, occasion: occasion, source: closet ? 'closet' : 'inspire', subject: subject),
      ),
    );
  }

  Future<String?> _ensureBodyPhoto(LooktokApi api) async {
    final existing = await api.bodyPhotoPath();
    if (existing != null) return existing;
    if (!mounted) return null;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.bg,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 4, 24, 12),
              child: Align(alignment: Alignment.centerLeft, child: Text('Add a full-body photo to style', style: AppType.body)),
            ),
            _SheetTile(icon: Icons.camera_alt_outlined, label: 'Take a photo', onTap: () => Navigator.pop(context, ImageSource.camera)),
            _SheetTile(icon: Icons.photo_library_outlined, label: 'Choose from gallery', onTap: () => Navigator.pop(context, ImageSource.gallery)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null) return null;
    final XFile? file;
    if (source == ImageSource.camera) {
      if (!mounted) return null;
      file = await Navigator.of(context).push<XFile?>(MaterialPageRoute(
          builder: (_) => const GuidedCameraScreen(config: GuidedCaptureConfig.body)));
    } else {
      file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 800, maxHeight: 800, imageQuality: 80);
    }
    if (file == null) return null;
    return api.uploadPhoto(await file.readAsBytes());
  }

  void _snack(String msg) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _fromCamera() async {
    final file = await Navigator.of(context).push<XFile?>(
      MaterialPageRoute(builder: (_) => const GuidedCameraScreen(config: GuidedCaptureConfig.outfit)),
    );
    if (file != null) _review(file);
  }

  Future<void> _fromGallery() async {
    // Telegram-style downscale on pick — smaller payload, faster upload + render.
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 800, maxHeight: 800, imageQuality: 75);
    if (file != null) _review(file);
  }

  // Ask whose look this is; for "me" require the owner profile, for a guest
  // collect their height/measurements — then analyze with the right body (§14.10).
  Future<void> _review(XFile file) async {
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    // Centralized interceptor: blurry / tiny / subject-less photos bounce
    // HERE (retake sheet) — before any upload, credit burn or 30s wait.
    if (!await PhotoValidator.instance
        .validateAndProceed(context, bytes, ValidationFlowType.fullBody)) {
      return;
    }
    if (!mounted) return;
    final subject = await askSubject(context, ref, photoBytes: bytes);
    if (subject == null || !mounted) return;
    if (subject.isMe) {
      if (!await ensureBodyProfile(context, ref)) return;
      if (!mounted) return;
    }
    _analyze(file, bytes, subject);
  }

  Future<void> _analyze(XFile file, Uint8List bytes, Subject subject) async {
    final profile = ref.read(profileProvider);
    if (ref.read(cloudEnabledProvider)) {
      // ABSOLUTE BAN on standalone checklist loaders (owner constraint 19.07):
      // the user lands on Edit Look IMMEDIATELY. Isolation, critique and slot
      // detection all resolve THERE, under the avatar's scanner overlay — no
      // dark screen, no route hidden behind an overlay.
      final fut = ref.read(smartImageProcessingProvider).processAndAnalyze(bytes,
          analysisType: SmartImageProcessingService.analysisReview,
          profile: profile,
          bodyOverride: subject.toOverride());
      final analysisFut = fut.then((r) {
        ref.invalidate(entitlementProvider);
        Analytics.avatarUploaded(success: true);
        return r.analysis!;
      }).catchError((Object e) {
        Analytics.avatarUploaded(success: false);
        throw e;
      });
      // Reuse the pipeline's isolation — the editor must never run a
      // duplicate on-device extraction for the same photo.
      final cleanFut = fut
          .then<Uint8List?>((r) => r.isolated ? r.cleanImage : null)
          .catchError((_) => null);
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LookEditorScreen(
            imageBytes: bytes,
            analysisFuture: analysisFut,
            cleanFuture: cleanFut,
            subject: subject),
      ));
      return;
    }
    // Legacy (non-cloud) path: the analyze call is synchronous-by-design here,
    // so the app-level overlay stays for it.
    final overlay = GlobalLoaderOverlay.instance;
    overlay.show(context, stages: const [
      'Isolating silhouette…',
      'Detecting color palette…',
      'Assessing fit & layering…',
      'Finalizing your style suggestions…',
    ]);
    try {
      final result = await ref.read(apiClientProvider).analyze(
          appUserId: ref.read(appUserIdProvider),
          base64Image: base64Encode(bytes),
          mimeType: file.mimeType ?? 'image/jpeg',
          profile: profile);
      ref.invalidate(entitlementProvider);
      if (!mounted) return overlay.hide();
      if (result.analyzable) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => LookEditorScreen(
              imageBytes: bytes,
              analysis: result,
              score: result.overallScore,
              subject: subject,
              onFullyReady: overlay.hide),
        ));
      } else {
        overlay.hide();
        _snack(result.note ?? 'That photo can’t be analyzed. Try a clear, full-body shot.');
      }
    } catch (e) {
      overlay.hide();
      ref.invalidate(entitlementProvider);
      if (mounted) _snack(e.toString());
    }
  }

  void _openWardrobe() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const WardrobeItemsScreen()));

  @override
  Widget build(BuildContext context) {
    final entitlement = ref.watch(entitlementProvider);
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: FrostedCanvas()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 10, 22, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Logo(size: 20),
                  const SizedBox(height: 30),
                  const _Greeting(),
                  const Spacer(),
                  entitlement.when(
                    data: (e) => _BalanceChip(entitlement: e),
                    loading: () => const SizedBox(height: 18),
                    error: (_, _) => const SizedBox(height: 18),
                  ),
                  const SizedBox(height: 14),
                  // Two killer features, given room to breathe (shopping flow
                  // deprecated) — taller primaries + a proper wardrobe card.
                  LooktokActionCard(
                    primary: true,
                    icon: Icons.auto_awesome,
                    title: 'Review my outfit',
                    subtitle: 'An honest, specific AI read',
                    onTap: _startReview,
                  ),
                  const SizedBox(height: 14),
                  LooktokActionCard(
                    icon: Icons.checkroom_outlined,
                    title: "Generate today's look",
                    subtitle: 'What should I wear?',
                    onTap: _openStylist,
                  ),
                  const SizedBox(height: 14),
                  LooktokActionCard(
                    icon: Icons.compare_arrows,
                    title: 'Compare',
                    subtitle: 'In a fitting room? Rank your try-ons',
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const CompareLooksScreen())),
                  ),
                  const SizedBox(height: 14),
                  LooktokActionCard(
                    icon: Icons.grid_view_rounded,
                    title: 'My wardrobe',
                    subtitle: 'Digitize clothes to build custom fits.',
                    onTap: _openWardrobe,
                  ),
                  // In-house 3D engine prototype (owner taste-check). Flip
                  // _k3dAtelier off to hide without touching the screen.
                  if (_k3dAtelier) ...[
                    const SizedBox(height: 14),
                    LooktokActionCard(
                      icon: Icons.view_in_ar_rounded,
                      title: 'Atelier',
                      subtitle: 'Your parametric avatar · beta',
                      onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const Atelier3dScreen())),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Frosted Canvas — a soft editorial backdrop: a faint hand-drawn fitting-room
/// triptych, muted into the near-white palette with a top scrim under the
/// greeting and a strong bottom scrim so the cards + tab bar stay crisp.
class FrostedCanvas extends StatelessWidget {
  const FrostedCanvas({super.key});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: AppColors.bg),
          Opacity(
            opacity: 0.14,
            child: Image.asset('assets/bg/home.jpg', fit: BoxFit.cover, alignment: Alignment.topCenter),
          ),
          // Vertical scrim: settle the greeting (top) and seat the cards (bottom).
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.bg.withValues(alpha: 0.50),
                  AppColors.bg.withValues(alpha: 0.02),
                  AppColors.bg.withValues(alpha: 0.92),
                ],
                stops: const [0.0, 0.38, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dynamic, contextual greeting (time-of-day for now; weather/location plugs in
/// here later). Massive, heavy, tight type per the editorial dashboard spec.
class _Greeting extends StatelessWidget {
  const _Greeting();
  @override
  Widget build(BuildContext context) {
    final h = TimeOfDay.now().hour;
    final (line, nudge) = h < 12
        ? ('Good\nmorning.', 'Let’s set today’s look.')
        : h < 17
            ? ('Good\nafternoon.', 'Time to sharpen your fit.')
            : h < 22
                ? ('Good\nevening.', 'Let’s build tonight’s look.')
                : ('Late\nnight.', 'Planning tomorrow’s look?');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(line,
            style: const TextStyle(fontSize: 52, height: 0.96, fontWeight: FontWeight.w800, letterSpacing: -2, color: AppColors.ink)),
        const SizedBox(height: 12),
        Text(nudge, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.inkSoft)),
      ],
    );
  }
}


/// Status badge above the hero card: dark metallic pill, crisp micro-type.
class _BalanceChip extends StatelessWidget {
  const _BalanceChip({required this.entitlement});
  final Map<String, dynamic> entitlement;
  @override
  Widget build(BuildContext context) {
    final pro = entitlement['pro'] == true;
    final left = entitlement['freeRemaining'] ?? 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2E2E33), Color(0xFF0A0A0A)],
        ),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: const [
          BoxShadow(color: Color(0x24000000), blurRadius: 10, offset: Offset(0, 3)),
        ],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (pro) ...[
          const Icon(Icons.auto_awesome, size: 11, color: AppColors.signature),
          const SizedBox(width: 5),
        ],
        Text(pro ? 'PRO · UNLIMITED' : '$left FREE REVIEWS LEFT',
            style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 10.5,
                letterSpacing: 1.3,
                color: Colors.white)),
      ]),
    );
  }
}



class _SheetTile extends StatelessWidget {
  const _SheetTile({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppColors.ink),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      onTap: onTap,
    );
  }
}
