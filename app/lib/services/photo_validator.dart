import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../theme.dart';
import 'native_looktok_engine.dart';

/// Which pipeline the photo is headed into — the rules differ.
enum ValidationFlowType {
  /// Onboarding body photo, Review selfie, Compare mirror shots.
  fullBody,

  /// Wardrobe item uploads (flat/hanger or worn).
  wardrobeItem,
}

class PhotoValidationResult {
  const PhotoValidationResult.ok()
      : ok = true,
        title = '',
        message = '',
        icon = null;
  const PhotoValidationResult.fail(this.title, this.message, this.icon) : ok = false;
  final bool ok;
  final String title;
  final String message;
  final IconData? icon;
}

/// Centralized ON-DEVICE photo validation — intercepts every photo input
/// (onboarding, wardrobe, review/compare) BEFORE background removal or any
/// network call. A doomed photo costs ~300ms locally instead of an upload,
/// an AI credit and a 30s wait.
///
/// Never throws; failures come back as `false` + a sleek bottom sheet naming
/// the exact reason with a Retake button.
class PhotoValidator {
  PhotoValidator._();
  static final PhotoValidator instance = PhotoValidator._();

  // Resolution floors. NOTE: deliberately below the brief's 720×1280 — our
  // pickers normalize to ≤800px (review) / ≤1600px (compare) on the long
  // side, so a hard 1280 floor would reject every legitimate photo. These
  // floors catch what they're meant to: thumbnails and screenshots-of-
  // screenshots, not phone photos.
  static const _minShortSideFullBody = 450;
  static const _minShortSideWardrobe = 320;

  /// Blur floor: Laplacian variance on 200px luma. Indoor mirror selfies
  /// score 40–200; genuine motion blur lands under ~15.
  static const _minSharpness = 15.0;

  /// Rules engine: resolution → sharpness → subject presence (native
  /// Vision/ML Kit; skipped silently on unsupported devices — validation
  /// must save doomed uploads, never brick the flow).
  Future<PhotoValidationResult> validate(Uint8List bytes, ValidationFlowType flow) async {
    final probe = await compute(_probe, bytes); // ONE decode: dims + sharpness
    if (probe == null) {
      return const PhotoValidationResult.fail(
          'Unreadable photo', 'That file couldn’t be read — pick a different photo.', Icons.broken_image_outlined);
    }
    final (w, h, sharpness) = (probe[0].toInt(), probe[1].toInt(), probe[2]);

    final minShort =
        flow == ValidationFlowType.fullBody ? _minShortSideFullBody : _minShortSideWardrobe;
    if (w < minShort || h < minShort) {
      return const PhotoValidationResult.fail(
          'Photo is too small',
          'This looks like a thumbnail. Use the camera or pick the original photo.',
          Icons.photo_size_select_large_outlined);
    }

    if (sharpness < _minSharpness) {
      return const PhotoValidationResult.fail(
          'Image is too blurry',
          'Hold the phone steadier or find better light, then retake.',
          Icons.blur_on_outlined);
    }

    if (await NativeLooktokEngine.instance.segmentationSupported()) {
      // Subject segmentation confidently finds people AND garments — the
      // right probe for both flows; only the failure copy differs.
      final subject = await NativeLooktokEngine.instance.extractSilhouette(bytes);
      if (subject == null) {
        return flow == ValidationFlowType.fullBody
            ? const PhotoValidationResult.fail(
                'Couldn’t find you in the shot',
                'Please stand further back so your full outfit is visible, then retake.',
                Icons.person_off_outlined)
            : const PhotoValidationResult.fail(
                'Couldn’t spot the garment',
                'Lay the piece flat or hang it with the whole item in frame, then retake.',
                Icons.checkroom_outlined);
      }
    }
    return const PhotoValidationResult.ok();
  }

  /// The interceptor: run the rules; on failure show the retake sheet and
  /// answer `false` — the caller simply aborts its flow. No exceptions.
  Future<bool> validateAndProceed(
      BuildContext context, Uint8List bytes, ValidationFlowType flow) async {
    final r = await validate(bytes, flow);
    if (r.ok) return true;
    if (context.mounted) {
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppColors.bg,
        showDragHandle: true,
        builder: (sheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(r.icon ?? Icons.error_outline, size: 30, color: AppColors.ink),
              const SizedBox(height: 12),
              Text(r.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
              const SizedBox(height: 6),
              Text(r.message, style: const TextStyle(color: AppColors.muted, fontSize: 14, height: 1.4)),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(sheet),
                  icon: const Icon(Icons.camera_alt_outlined, size: 18),
                  label: const Text('Retake photo'),
                ),
              ),
            ]),
          ),
        ),
      );
    }
    return false;
  }
}

/// Isolate worker: one decode → [width, height, Laplacian variance].
List<double>? _probe(Uint8List bytes) {
  try {
    final full = img.decodeImage(bytes);
    if (full == null) return null;
    final w = full.width.toDouble(), h = full.height.toDouble();
    final small = img.grayscale(img.copyResize(full, width: 200));
    final sw = small.width, sh = small.height;
    double sum = 0, sumSq = 0;
    final n = (sw - 2) * (sh - 2);
    if (n <= 0) return [w, h, 999];
    num luma(int x, int y) => small.getPixel(x, y).r;
    for (var y = 1; y < sh - 1; y++) {
      for (var x = 1; x < sw - 1; x++) {
        final l = 4 * luma(x, y) - luma(x - 1, y) - luma(x + 1, y) - luma(x, y - 1) - luma(x, y + 1);
        sum += l;
        sumSq += l * l;
      }
    }
    final mean = sum / n;
    return [w, h, sumSq / n - mean * mean];
  } catch (_) {
    return null;
  }
}
