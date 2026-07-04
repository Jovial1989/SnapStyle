import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../camera/guided_camera_screen.dart';
import '../models/body_profile.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/shimmer.dart';

enum _Step { height, analyzing, result }

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _height = TextEditingController();
  _Step _step = _Step.height;
  BodyProfile? _profile;
  String? _error;

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
    setState(() => _error = null);
    // Height is valid → let the user take OR upload a full-body photo.
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
            source: ImageSource.gallery, maxWidth: 1568, maxHeight: 1568, imageQuality: 85);
    if (file == null) return;

    setState(() => _step = _Step.analyzing);
    try {
      final bytes = await file.readAsBytes();
      // Local path: base64 straight to the Node backend (no Supabase/auth).
      final profile = await ref.read(apiClientProvider).onboardingProfileLocal(
            base64Image: base64Encode(bytes),
            mimeType: file.mimeType ?? 'image/jpeg',
            heightCm: h,
          );
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _step = _Step.result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _step = _Step.height;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Build your profile')),
      body: SafeArea(
        child: switch (_step) {
          _Step.height => _HeightStep(
              controller: _height,
              error: _error,
              onContinue: _captureAndAnalyze,
            ),
          _Step.analyzing => const _AnalyzingStep(),
          _Step.result => _ResultStep(profile: _profile!),
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
          const Text('We use your height to scale proportions from your photo.',
              style: TextStyle(color: AppColors.muted, height: 1.4, fontSize: 16)),
          const SizedBox(height: 28),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              suffixText: 'cm',
              border: const OutlineInputBorder(),
              errorText: error,
            ),
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
              SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text('AI is analyzing your proportions…',
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
                SizedBox(height: 8),
                ShimmerBox(height: 14, width: 240),
                SizedBox(height: 24),
                ShimmerBox(height: 56, radius: 16),
                SizedBox(height: 12),
                ShimmerBox(height: 56, radius: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultStep extends StatelessWidget {
  const _ResultStep({required this.profile});
  final BodyProfile profile;

  @override
  Widget build(BuildContext context) {
    final measures = <String, String?>{
      'Chest': profile.chest.label,
      'Waist': profile.waist.label,
      'Hip': profile.hip.label,
      'Inseam': profile.inseam.label,
    }..removeWhere((_, v) => v == null);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(profile.bodyType?.replaceAll('_', ' ') ?? 'Your profile',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
              if (profile.proportionDescription != null) ...[
                const SizedBox(height: 8),
                Text(profile.proportionDescription!,
                    style: const TextStyle(color: Colors.white, height: 1.4)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (measures.isNotEmpty) ...[
          const Text('Estimated measurements',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('Approximate ranges inferred from your photo — not exact measurements.',
              style: TextStyle(color: AppColors.muted, fontSize: 13)),
          const SizedBox(height: 12),
          ...measures.entries.map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(e.key, style: const TextStyle(color: AppColors.muted)),
                    Text(e.value!, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              )),
          const SizedBox(height: 20),
        ],
        if (profile.stylingNotes.isNotEmpty) ...[
          const Text('What flatters you',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          ...profile.stylingNotes.map((n) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('• $n', style: const TextStyle(height: 1.4)),
              )),
          const SizedBox(height: 24),
        ],
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Start styling'),
        ),
      ],
    );
  }
}
