import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../providers.dart';
import '../theme.dart';

/// "Vibe Check" — visual Style DNA onboarding (SDD §14.12). The user drops 1–3
/// reference looks / moodboard screenshots; we decode the styling rules. A
/// prominent Skip seeds the smart fallback anchor instead. Editorial Luxury,
/// dark register (stark black surface + cobalt accent).
class VibeCheckScreen extends ConsumerStatefulWidget {
  const VibeCheckScreen({super.key});
  @override
  ConsumerState<VibeCheckScreen> createState() => _VibeCheckScreenState();
}

class _VibeCheckScreenState extends ConsumerState<VibeCheckScreen> {
  final List<Uint8List> _images = [];
  bool _busy = false;

  String get _locale => ui.PlatformDispatcher.instance.locale.toLanguageTag();

  Future<void> _pick() async {
    if (_images.length >= 3 || _busy) return;
    final file = await ImagePicker()
        .pickImage(source: ImageSource.gallery, maxWidth: 800, maxHeight: 800, imageQuality: 80);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (mounted) setState(() => _images.add(bytes));
  }

  Future<void> _finish({required bool skip}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (ref.read(cloudEnabledProvider)) {
        await ref.read(looktokApiProvider).vibeCheck(
              images: skip ? const [] : _images,
              locale: _locale,
              skip: skip,
            );
      }
      if (mounted) Navigator.of(context).pop(!skip);
    } catch (_) {
      // Never block onboarding on this — proceed; the fallback can seed later.
      if (mounted) Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canContinue = _images.isNotEmpty && !_busy;
    return Scaffold(
      backgroundColor: AppColors.ink,
      appBar: AppBar(
        backgroundColor: AppColors.ink,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          TextButton(
            onPressed: _busy ? null : () => _finish(skip: true),
            child: const Text('Skip',
                style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Show us\nwhat you like.',
                  style: TextStyle(color: Colors.white, fontSize: 40, height: 1.02, fontWeight: FontWeight.w800, letterSpacing: -1.5)),
              const SizedBox(height: 14),
              const Text(
                'Upload 1–3 outfits that inspire you — your own best looks or a moodboard screenshot. We’ll decode the styling rules.',
                style: TextStyle(color: Colors.white70, height: 1.45, fontSize: 15),
              ),
              const SizedBox(height: 32),
              Row(
                children: List.generate(3, (i) {
                  final filled = i < _images.length;
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: i < 2 ? 12 : 0),
                      child: AspectRatio(
                        aspectRatio: 3 / 4,
                        child: filled
                            ? _FilledTile(bytes: _images[i], onRemove: () => setState(() => _images.removeAt(i)))
                            : _EmptyTile(onTap: _pick, isNext: i == _images.length),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 16),
              Row(
                children: const [
                  Icon(Icons.lock_outline, size: 13, color: Colors.white38),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text('Private to you. Used only to tune your style — never shared, never sold.',
                        style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.35)),
                  ),
                ],
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: canContinue ? () => _finish(skip: false) : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.ink,
                    disabledBackgroundColor: Colors.white24,
                    disabledForegroundColor: Colors.white38,
                    minimumSize: const Size.fromHeight(56),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.pill)),
                  ),
                  child: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.ink))
                      : Text('Decode my style${_images.isEmpty ? '' : ' (${_images.length})'}',
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: _busy ? null : () => _finish(skip: true),
                  child: const Text('I’ll do this later',
                      style: TextStyle(color: Colors.white54, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyTile extends StatelessWidget {
  const _EmptyTile({required this.onTap, required this.isNext});
  final VoidCallback onTap;
  final bool isNext; // the next slot to fill → brighter affordance
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(
            color: isNext ? AppColors.signature.withValues(alpha: 0.7) : Colors.white24,
            width: isNext ? 1.5 : 1,
          ),
        ),
        child: Center(
          child: Icon(Icons.add, size: 26, color: isNext ? AppColors.signature : Colors.white38),
        ),
      ),
    );
  }
}

class _FilledTile extends StatelessWidget {
  const _FilledTile({required this.bytes, required this.onRemove});
  final Uint8List bytes;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Image.memory(bytes, fit: BoxFit.cover),
        ),
        Positioned(
          top: 6,
          right: 6,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(color: Color(0xCC0A0A0A), shape: BoxShape.circle),
              child: const Icon(Icons.close, size: 15, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}
