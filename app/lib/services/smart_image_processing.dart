import 'dart:convert';
import 'dart:typed_data';

import '../models/analysis.dart';
import '../models/profile.dart';
import '../utils/webp_payload.dart';
import 'local_segmenter.dart';
import 'mask_generation.dart';
import 'native_looktok_engine.dart';
import 'looktok_api.dart';

/// One front door for every "photo in → AI verdict out" flow. All flows share
/// the same two-hop pipeline: (1) isolate a clean transparent-PNG silhouette —
/// Gemini judges the clothes, not the messy fitting room behind them — then
/// (2) hand the clean image to the right Edge Function.
///
/// Isolation is ON-DEVICE first, with a graceful cascade that always completes:
/// native engine (Apple Vision / ML Kit subject segmentation — best masks,
/// ~instant) → the Flutter selfie-segmentation plugin → the remote rembg
/// service → the ORIGINAL bytes.
class SmartImageProcessingService {
  SmartImageProcessingService(this._api, {Future<bool> Function()? sam2Gate})
      : _sam2Gate = sam2Gate;
  final LooktokApi _api;
  final Future<bool> Function()? _sam2Gate; // feature flag + dev override

  static const analysisCompare = 'compare';
  static const analysisReview = 'review_outfit';
  static const analysisWardrobe = 'wardrobe_digitize';

  /// Mask engine policy: the EXPERIMENTAL SAM 2 worker first (only in builds
  /// with --dart-define=SAM2_ENGINE_URL, strict 3s deadline, session circuit
  /// breaker), then the proven legacy cascade. Production builds without the
  /// define run the legacy cascade directly — zero behavior change.
  late final MaskGenerationController _masks = MaskGenerationController(
    legacy: LegacyMaskStrategy(_legacyCascade),
    experimental: Sam2MaskStrategy.configured ? Sam2MaskStrategy() : null,
    gate: _sam2Gate,
  );

  Future<Uint8List> _isolate(Uint8List rawImage) => _masks.generateMask(rawImage);

  /// STRICT isolation: null when every engine failed. The lenient cascade
  /// returns the ORIGINAL BYTES OBJECT on total failure — identity is the
  /// truth signal (new buffers mean a real cutout was produced).
  Future<Uint8List?> _isolateStrict(Uint8List rawImage) async {
    final out = await _masks.generateMask(rawImage);
    return identical(out, rawImage) ? null : out;
  }

  /// The battle-tested cascade: native engine → ML Kit selfie plugin → remote
  /// rembg → original bytes. Never throws — the last resort is the original.
  Future<Uint8List> _legacyCascade(Uint8List rawImage) async {
    final native = await NativeLooktokEngine.instance.extractSilhouette(rawImage);
    if (native != null) return native;
    try {
      return await LocalSegmenter.instance.isolate(rawImage);
    } catch (_) {
      // No usable local mask (unsupported device, undecodable photo, subject
      // too small). The remote call already returns the original on failure,
      // and its POST auto-starts the scale-to-zero machine by itself.
      return _api.removeBackground(rawImage);
    }
  }

  /// Single-image flows: `review_outfit` (critique) and `wardrobe_digitize`.
  Future<ProcessedAnalysis> processAndAnalyze(
    Uint8List rawImage, {
    required String analysisType,
    StyleProfile? profile,
    Map<String, dynamic>? bodyOverride, // guest body (review only)
    String? category, // wardrobe only
    bool isWorn = false, // wardrobe only
    void Function(Uint8List cleaned)? onIsolated, // streams the sprite to the UI
  }) async {
    switch (analysisType) {
      case analysisReview:
        // Strict: a failed isolation must NEVER masquerade as a clean sprite
        // (that's how the raw street scene ended up on the editor avatar).
        final clean = await _isolateStrict(rawImage);
        if (clean != null) onIsolated?.call(clean);
        final judged = clean ?? rawImage;
        final analysis = await _api.analyze(
          base64Image: base64Encode(judged),
          mimeType: _mime(judged),
          profile: profile,
          bodyOverride: bodyOverride,
        );
        return ProcessedAnalysis(
            cleanImage: judged, isolated: clean != null, analysis: analysis);
      case analysisWardrobe:
        // Flat/hanger shots: the native engine isolates the GARMENT on-device
        // (Vision/ML Kit subject segmentation handles objects, not just
        // people) — the EF then skips its own server-side rembg hop.
        // Worn shots stay server-routed: extracting "only the jacket" from a
        // dressed person is semantic work, Gemini's job — a subject mask
        // would cut out the whole person.
        final cut = isWorn ? null : await NativeLooktokEngine.instance.extractSilhouette(rawImage);
        final item = await _api.addWardrobeItem(cut ?? rawImage,
            category: category,
            isWorn: isWorn,
            preIsolated: cut != null,
            original: cut != null ? rawImage : null);
        return ProcessedAnalysis(cleanImage: cut ?? rawImage, item: item);
      default:
        throw ArgumentError.value(analysisType, 'analysisType',
            'use processAndCompare for "$analysisCompare", or one of: $analysisReview, $analysisWardrobe');
    }
  }

  /// `compare` — 2–4 mirror selfies, ranked. [onCleaned] streams the isolated
  /// silhouettes to the UI the moment they're ready, so the loader can swap
  /// raw mirror photos for clean cutouts mid-flight.
  Future<ProcessedComparison> processAndCompare(
    List<Uint8List> rawImages, {
    void Function(List<Uint8List> cleaned)? onCleaned,
    String mode = 'looks',
  }) async {
    // Concurrent fan-out is safe: LocalSegmenter serializes its native calls
    // internally, and the remote fallback path was always concurrent.
    final cleaned = await Future.wait([for (final b in rawImages) _isolate(b)]);
    onCleaned?.call(cleaned);
    final looks = await _api.compareLooks(cleaned, mode: mode);
    return ProcessedComparison(cleanImages: cleaned, looks: looks);
  }

  /// Magic-byte sniff (PNG / WebP / JPEG) — engines answer different formats.
  static String _mime(Uint8List b) => imageMime(b);
}

/// Result of a single-image pipeline run: the image the AI actually judged
/// (clean silhouette, or the original on fallback) + the flow's payload.
class ProcessedAnalysis {
  const ProcessedAnalysis(
      {required this.cleanImage, this.isolated = true, this.analysis, this.item});
  final Uint8List cleanImage;

  /// FALSE when isolation failed end-to-end and [cleanImage] is actually the
  /// original — consumers must not treat it as a transparent sprite.
  final bool isolated;
  final AnalysisResult? analysis; // review_outfit
  final Map<String, dynamic>? item; // wardrobe_digitize
}

/// Result of the compare pipeline: silhouettes by original index + ranked looks.
class ProcessedComparison {
  const ProcessedComparison({required this.cleanImages, required this.looks});
  final List<Uint8List> cleanImages;
  final List<Map<String, dynamic>> looks; // sorted best-first: {index, score, title?, why}
}
