import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../providers.dart';
import '../theme.dart';

/// Onboarding step (optional, skippable) — collect 2–10 of the user's own
/// outfit photos. They're saved as "reference looks"; a SILENT backend job then
/// pre-generates a personal lookbook shown on the Review loader. We never tell
/// the user "we're generating" — it just quietly makes their feed better.
/// Dark register to match VibeCheck.
class SelectLooksScreen extends ConsumerStatefulWidget {
  const SelectLooksScreen({super.key});
  @override
  ConsumerState<SelectLooksScreen> createState() => _SelectLooksScreenState();
}

class _SelectLooksScreenState extends ConsumerState<SelectLooksScreen> {
  final List<Uint8List> _images = [];
  bool _busy = false;
  static const _max = 10;
  static const _min = 2;

  Future<void> _pick() async {
    if (_images.length >= _max || _busy) return;
    final files = await ImagePicker()
        .pickMultiImage(maxWidth: 800, maxHeight: 800, imageQuality: 80, limit: _max - _images.length);
    if (files.isEmpty) return;
    for (final f in files) {
      if (_images.length >= _max) break;
      _images.add(await f.readAsBytes());
    }
    if (mounted) setState(() {});
  }

  Future<void> _finish({required bool skip}) async {
    if (_busy) return;
    if (skip || _images.isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() => _busy = true);
    try {
      if (ref.read(cloudEnabledProvider)) {
        await ref.read(looktokApiProvider).saveReferenceLooks(_images);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      // Never block onboarding — the feed silently falls back to trends.
      if (mounted) Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canContinue = _images.length >= _min && !_busy;
    final tiles = _images.length < _max ? _images.length + 1 : _images.length;
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
              const Text('Add a few\nof your looks.',
                  style: TextStyle(color: Colors.white, fontSize: 40, height: 1.02, fontWeight: FontWeight.w800, letterSpacing: -1.5)),
              const SizedBox(height: 14),
              const Text(
                'Drop in 2–10 outfits you actually wear. We build you a personal lookbook from them, so your reviews come with looks that fit you.',
                style: TextStyle(color: Colors.white70, height: 1.45, fontSize: 15),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 3 / 4,
                  ),
                  itemCount: tiles,
                  itemBuilder: (context, i) {
                    if (i < _images.length) {
                      return _FilledTile(bytes: _images[i], onRemove: _busy ? null : () => setState(() => _images.removeAt(i)));
                    }
                    return _EmptyTile(onTap: _pick, isNext: _images.isEmpty);
                  },
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.lock_outline, size: 13, color: Colors.white38),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _images.isEmpty
                          ? 'Private to you — never shared, never sold. Inspiration only.'
                          : '${_images.length}/$_max added${_images.length < _min ? ' · add ${_min - _images.length} more' : ''}',
                      style: const TextStyle(color: Colors.white38, fontSize: 12, height: 1.35),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
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
                      : Text('Save my looks${_images.isEmpty ? '' : ' (${_images.length})'}',
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
  final bool isNext;
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
  final VoidCallback? onRemove;
  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Image.memory(bytes, fit: BoxFit.cover),
        ),
        if (onRemove != null)
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
