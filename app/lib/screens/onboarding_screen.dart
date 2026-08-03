import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../camera/guided_camera_screen.dart';
import '../models/body_profile.dart';
import '../providers.dart';
import '../services/photo_validator.dart';
import '../theme.dart';
import '../widgets/shimmer.dart';

enum _Step { height, analyzing, confirm }

const _bodyTypes = ['rectangle', 'triangle', 'inverted_triangle', 'hourglass', 'oval', 'athletic'];
/// Body-profile builder: height → full-body photo → AI estimate → user confirms
/// / corrects → saved (SDD §14.2). Required before any review/look flow; can be
/// skipped from the post-auth offer ([skippable] = true).
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.skippable = false});
  final bool skippable;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _height = TextEditingController();
  _Step _step = _Step.height;
  BodyProfile? _profile;
  String? _bodyType; // user-editable, seeded from the AI estimate
  int _heightCm = 0;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _height.dispose();
    super.dispose();
  }

  void _captureAndAnalyze() {
    final h = int.tryParse(_height.text.trim());
    if (h == null || h < 100 || h > 250) {
      setState(() => _error = 'Enter a height between 100 and 250 cm');
      return;
    }
    setState(() {
      _error = null;
      _heightCm = h;
    });
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.bg,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined, color: AppColors.ink),
              title: const Text('Take a photo', style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(context);
                _run(h, fromCamera: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: AppColors.ink),
              title: const Text('Upload from gallery', style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(context);
                _run(h, fromCamera: false);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _run(int h, {required bool fromCamera}) async {
    final nav = Navigator.of(context); // capture before any await
    final XFile? file = fromCamera
        ? await nav.push<XFile?>(MaterialPageRoute(
            builder: (_) => const GuidedCameraScreen(config: GuidedCaptureConfig.body)))
        : await ImagePicker().pickImage(
            source: ImageSource.gallery, maxWidth: 800, maxHeight: 800, imageQuality: 80);
    if (file == null) return;

    final bytes = await file.readAsBytes();
    if (!mounted) return;
    // Centralized interceptor: the body photo drives EVERY later flow — a
    // blurry or headless shot here poisons all of them. Bounce it with the
    // retake sheet before the upload + profiling call.
    if (!await PhotoValidator.instance
        .validateAndProceed(context, bytes, ValidationFlowType.fullBody)) {
      return; // stay on the height step; the user retakes
    }
    if (!mounted) return;
    setState(() => _step = _Step.analyzing);
    try {
      final BodyProfile profile;
      if (ref.read(cloudEnabledProvider)) {
        final api = ref.read(looktokApiProvider);
        final path = await api.uploadPhoto(bytes);
        profile = await api.onboardingProfile(photoPath: path, heightCm: h);
      } else {
        profile = await ref.read(apiClientProvider).onboardingProfileLocal(
              base64Image: base64Encode(bytes),
              mimeType: file.mimeType ?? 'image/jpeg',
              heightCm: h,
            );
      }
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _bodyType = profile.bodyType ?? _bodyTypes.first;
        _step = _Step.confirm;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _step = _Step.height;
      });
    }
  }

  Future<void> _confirm() async {
    setState(() => _saving = true);
    try {
      if (ref.read(cloudEnabledProvider)) {
        await ref.read(looktokApiProvider).confirmBodyProfile(bodyType: _bodyType, heightCm: _heightCm);
      }
      // Mirror height locally so the Profile form + prompts stay in sync.
      final p = ref.read(profileProvider);
      await ref.read(profileProvider.notifier).update(p.copyWith(heightCm: _heightCm));
      ref.invalidate(bodyProfileProvider); // refresh home card + Profile
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Build your profile'),
        actions: [
          if (widget.skippable && _step == _Step.height)
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Skip')),
        ],
      ),
      body: SafeArea(
        child: switch (_step) {
          _Step.height => _HeightStep(controller: _height, error: _error, onContinue: _captureAndAnalyze),
          _Step.analyzing => const _AnalyzingStep(),
          _Step.confirm => _RevealStep(
              profile: _profile!,
              saving: _saving,
              onConfirm: _confirm,
            ),
        },
      ),
    );
  }
}

class _HeightStep extends StatelessWidget {
  const _HeightStep({required this.controller, required this.error, required this.onContinue});
  final TextEditingController controller;
  final String? error;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('How tall are you?',
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: -1)),
          const SizedBox(height: 8),
          const Text('We use your height to scale proportions from your photo — the AI does the rest.',
              style: TextStyle(color: AppColors.muted, height: 1.4, fontSize: 16)),
          const SizedBox(height: 28),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
                suffixText: 'cm', border: const OutlineInputBorder(), errorText: error),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: onContinue,
            icon: const Icon(Icons.add_a_photo_outlined, size: 18, color: AppColors.signature),
            label: const Text('Add full-body photo'),
          ),
        ],
      ),
    );
  }
}

class _AnalyzingStep extends StatelessWidget {
  const _AnalyzingStep();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Row(
            children: const [
              SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text('AI is reading your proportions…',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            ],
          ),
          const SizedBox(height: 28),
          Shimmer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                ShimmerBox(height: 120, radius: 20),
                SizedBox(height: 16),
                ShimmerBox(height: 20, width: 180),
                SizedBox(height: 12),
                ShimmerBox(height: 14),
                SizedBox(height: 24),
                ShimmerBox(height: 56, radius: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The "Magic Reveal" (SDD §14.2 rev): the AI's read presented as a premium,
/// immutable fact — big type, the dark read card, what flatters you, ONE
/// button. No dropdowns, no corrections: users don't know their own body
/// type, so asking them to pick one was pure friction.
class _RevealStep extends StatelessWidget {
  const _RevealStep({
    required this.profile,
    required this.saving,
    required this.onConfirm,
  });
  final BodyProfile profile;
  final bool saving;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final measures = <String, String?>{
      'Chest': profile.chest.label,
      'Waist': profile.waist.label,
      'Hip': profile.hip.label,
      'Inseam': profile.inseam.label,
    }..removeWhere((_, v) => v == null);

    return Column(children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
          children: [
            // The reveal — plain words, zero stylist taxonomy ("inverted
            // triangle" reads like a diagnosis; the AI keeps the label
            // internally, the human gets the meaning).
            const Text('YOUR PROFILE',
                style: TextStyle(
                    color: AppColors.muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 2)),
            const SizedBox(height: 6),
            const Text(
              'Your build,\ndecoded.',
              style: TextStyle(fontSize: 42, fontWeight: FontWeight.w800, letterSpacing: -1.5, height: 1.05),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(20)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('HERE’S OUR READ',
                      style: TextStyle(
                          color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 2)),
                  const SizedBox(height: 8),
                  Text(
                    profile.proportionDescription ?? 'We estimated your build from your photo.',
                    style: const TextStyle(color: Colors.white, height: 1.4, fontSize: 15),
                  ),
                  if (measures.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Container(height: 1, color: Colors.white12),
                    const SizedBox(height: 14),
                    // Read-only proof of the read — approximate ranges, quiet.
                    ...measures.entries.map((e) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(e.key, style: const TextStyle(color: Colors.white54, fontSize: 13)),
                              Text(e.value!,
                                  style: const TextStyle(
                                      color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                            ],
                          ),
                        )),
                  ],
                ],
              ),
            ),
            if (profile.stylingNotes.isNotEmpty) ...[
              const SizedBox(height: 26),
              const Text('What flatters you', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              ...profile.stylingNotes.map((n) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('• $n', style: const TextStyle(height: 1.4)),
                  )),
            ],
          ],
        ),
      ),
      // The single action on this screen — pinned, always visible.
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: saving ? null : onConfirm,
            child: saving
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Got it — let’s style',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          ),
        ),
      ),
    ]);
  }
}
