import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../camera/guided_camera_screen.dart';
import '../paywall_gate.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/wordmark.dart';
import 'onboarding_screen.dart';
import 'processing_screen.dart';
import 'result_screen.dart';

class HomeTab extends ConsumerStatefulWidget {
  const HomeTab({super.key});
  @override
  ConsumerState<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends ConsumerState<HomeTab> {
  // ── Fit Check: gate tokens, then choose camera/gallery ──
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
            _SheetTile(
              icon: Icons.camera_alt_outlined,
              label: 'Take a photo',
              onTap: () {
                Navigator.pop(context);
                _fromCamera();
              },
            ),
            _SheetTile(
              icon: Icons.photo_library_outlined,
              label: 'Choose from gallery',
              onTap: () {
                Navigator.pop(context);
                _fromGallery();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Wardrobe Mode: occasion chips (Journey B) ──
  void _openOccasions() {
    const occasions = ['Office', 'Date', 'Pub', 'Active', 'Hot weather'];
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.bg,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('What should I wear?', style: AppType.h2),
              const SizedBox(height: 6),
              const Text('Pick an occasion — we build a look from your wardrobe.',
                  style: AppType.body),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: occasions
                    .map((o) => ActionChip(
                          label: Text(o),
                          backgroundColor: AppColors.surface,
                          side: const BorderSide(color: AppColors.line),
                          onPressed: () {
                            Navigator.pop(context);
                            _runWardrobe(o);
                          },
                        ))
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _runWardrobe(String occasion) async {
    if (!await ensureTokens(context, ref)) return; // paywall interceptor
    if (!mounted) return;
    // Journey B generation is blocked on the Digital Wardrobe (SDD §14.5).
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.bg,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('“$occasion” outfit', style: AppType.h2),
            const SizedBox(height: 8),
            const Text(
              'Wardrobe outfits build from items you own. Add pieces to your wardrobe first — this flow is coming next.',
              style: AppType.body,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _fromCamera() async {
    final file = await Navigator.of(context).push<XFile?>(
      MaterialPageRoute(builder: (_) => const GuidedCameraScreen(config: GuidedCaptureConfig.outfit)),
    );
    if (file != null) _analyze(file);
  }

  Future<void> _fromGallery() async {
    final file = await ImagePicker()
        .pickImage(source: ImageSource.gallery, maxWidth: 1568, maxHeight: 1568, imageQuality: 85);
    if (file != null) _analyze(file);
  }

  Future<void> _analyze(XFile file) async {
    final bytes = await file.readAsBytes();
    final api = ref.read(apiClientProvider);
    if (!mounted) return;
    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProcessingScreen(
          messages: const [
            'Analyzing fit…',
            'Checking proportions…',
            'Matching footwear…',
            'Assessing layering…',
          ],
          task: api.analyze(
            appUserId: ref.read(appUserIdProvider),
            base64Image: base64Encode(bytes),
            mimeType: file.mimeType ?? 'image/jpeg',
            profile: ref.read(profileProvider),
          ),
        ),
      ),
    );
    ref.invalidate(entitlementProvider);
    if (!mounted) return;
    if (result is ProcessingError) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(result.message)));
    } else if (result != null) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ResultScreen(result: result, imageBytes: bytes)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final entitlement = ref.watch(entitlementProvider);
    return Scaffold(
      appBar: AppBar(title: const Logo(size: 22), toolbarHeight: 60),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 28),
              const Text('How does\nit really look?', style: AppType.display),
              const SizedBox(height: 14),
              const Text(
                'Snap your outfit. Get an honest, specific read — fit, proportion, footwear, layering.',
                style: AppType.body,
              ),
              const Spacer(),
              entitlement.when(
                data: (e) => _FreeBadge(entitlement: e),
                loading: () => const SizedBox(height: 20),
                error: (_, _) => const Text('Backend offline — start the Node server.',
                    style: TextStyle(color: AppColors.muted, fontSize: 12)),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _startReview,
                // Signature accent on the AI sparkle — draws the eye, keeps the
                // button matte black (SDD §9.6).
                icon: const Icon(Icons.auto_awesome, size: 18, color: AppColors.signature),
                label: const Text('Review my outfit'),
              ),
              const SizedBox(height: 10),
              _WardrobeCard(onTap: _openOccasions),
              const SizedBox(height: 10),
              _ProfileCard(
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const OnboardingScreen())),
              ),
            ],
          ),
        ),
      ),
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

class _FreeBadge extends StatelessWidget {
  const _FreeBadge({required this.entitlement});
  final Map<String, dynamic> entitlement;
  @override
  Widget build(BuildContext context) {
    final pro = entitlement['pro'] == true;
    final remaining = entitlement['freeRemaining'] ?? 0;
    return Row(
      children: [
        const Icon(Icons.circle, size: 7, color: AppColors.ink),
        const SizedBox(width: 8),
        Text(
          pro ? 'Pro · unlimited reviews' : '$remaining free reviews left',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
      ],
    );
  }
}

class _WardrobeCard extends StatelessWidget {
  const _WardrobeCard({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: [
            const Icon(Icons.checkroom, size: 20, color: AppColors.signature),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('What should I wear?',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  SizedBox(height: 2),
                  Text('Build a look for any occasion',
                      style: TextStyle(color: AppColors.muted, fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward, size: 18, color: AppColors.muted),
          ],
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: AppDecorations.neuCard,
        child: Row(
          children: [
            const Icon(Icons.straighten, size: 20, color: AppColors.ink),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Build your body profile',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  SizedBox(height: 2),
                  Text('Sharper advice on proportion & cut',
                      style: TextStyle(color: AppColors.muted, fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward, size: 18, color: AppColors.muted),
          ],
        ),
      ),
    );
  }
}
