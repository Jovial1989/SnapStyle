import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

import 'autocrop.dart';

/// Network-payload compression for images (incl. TRANSPARENT PNGs — WebP
/// carries alpha natively, so silhouettes survive intact).
///
/// Returns WebP @[quality] when the platform encoder can produce one that is
/// actually smaller; otherwise returns the ORIGINAL bytes untouched. That
/// fallback is load-bearing: iOS has no system WebP encoder (the plugin
/// throws there), and a "compressed" payload larger than the source would be
/// pure loss. Callers always get sendable bytes + must pick the mime type
/// via [imageMime], never by assumption.
Future<Uint8List> toWebPPayload(Uint8List bytes, {int quality = 85}) async {
  try {
    final out = await FlutterImageCompress.compressWithList(
      bytes,
      format: CompressFormat.webp,
      quality: quality,
      keepExif: false,
    );
    if (out.isNotEmpty && out.length < bytes.length) return out;
  } catch (_) {
    // Platform can't encode WebP — ship the original.
  }
  return bytes;
}

/// TRY-ON transport payload: hard-capped near 768×1024 (never upscaled).
/// Prefers WebP; falls back to a RESIZED PNG — load-bearing on iOS, which
/// ships no system WebP encoder, so [toWebPPayload] silently returned the
/// raw full-size cutout there. A 768px PNG is ~4× lighter than the 1600px
/// original (alpha intact), cutting both upload time and Gemini input size;
/// stable bytes also keep the backend try-on cache key deterministic.
Future<Uint8List> toTryonPayload(Uint8List bytes, {int quality = 85}) async {
  // FLATTEN ONTO WHITE FIRST: the isolation step hands us a TRANSPARENT cutout,
  // and shipping that alpha to Gemini caused edge halos ("следы фона") and
  // IMAGE_OTHER refusals. Compositing onto opaque white here — deterministically,
  // client-side — gives the model a clean white-backed subject with nothing to
  // hallucinate around. JPEG (no alpha) also compresses smaller downstream.
  var src = bytes;
  try {
    final flat = await compute(flattenOnWhite, bytes);
    if (flat.isNotEmpty) src = flat;
  } catch (_) {/* keep the original if flatten fails */}
  try {
    final out = await FlutterImageCompress.compressWithList(
      src,
      minWidth: 768,
      minHeight: 1024,
      format: CompressFormat.webp,
      quality: quality,
      keepExif: false,
    );
    if (out.isNotEmpty && out.length < src.length) return out;
  } catch (_) {
    // No WebP encoder on this platform — try the PNG resize path.
  }
  try {
    final out = await FlutterImageCompress.compressWithList(
      src,
      minWidth: 768,
      minHeight: 1024,
      format: CompressFormat.jpeg,
      quality: 90,
      keepExif: false,
    );
    if (out.isNotEmpty) return out;
  } catch (_) {/* ship the flattened source */}
  return src;
}

/// Magic-byte sniffing — the ONLY safe way to label a payload whose format
/// depends on which compression path succeeded.
String imageMime(Uint8List b) {
  if (b.length > 4 && b[0] == 0x89 && b[1] == 0x50) return 'image/png';
  if (b.length > 12 &&
      b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && // RIFF
      b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) { // WEBP
    return 'image/webp';
  }
  return 'image/jpeg';
}

/// File extension matching [imageMime] — for multipart filenames.
String imageExt(Uint8List b) => switch (imageMime(b)) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      _ => 'jpg',
    };
