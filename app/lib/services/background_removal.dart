import 'dart:typed_data';

import 'native_looktok_engine.dart';

/// On-device background removal — the privacy/zero-cost/<150ms path.
///
/// This is a FACADE over [NativeLooktokEngine] (channel
/// `com.looktok.app/engine`), which already carries the full native stack:
/// Apple Vision `VNGenerateForegroundInstanceMaskRequest` on iOS 17+ (with a
/// person-segmentation fallback on 15.5–16) and ML Kit Subject Segmentation
/// on Android. One channel, one native handler — a parallel
/// `com.looktok.app/vision` channel would duplicate that code verbatim.
///
/// Contract: image file path in → transparent PNG bytes out; `null` on any
/// failure (unsupported OS, no confident subject, missing native impl) so
/// callers can fall back — nothing here ever throws.
class BackgroundRemovalService {
  BackgroundRemovalService._();
  static final BackgroundRemovalService instance = BackgroundRemovalService._();

  /// True when this device can segment on the NPU (iOS 15.5+ / Android 24+
  /// with the ML Kit module available).
  Future<bool> isSupported() =>
      NativeLooktokEngine.instance.segmentationSupported();

  /// Remove the background from the image at [imagePath] → transparent PNG.
  Future<Uint8List?> removeBackground(String imagePath) =>
      NativeLooktokEngine.instance.extractSilhouetteFromFile(imagePath);

  /// Bytes-in convenience (stages through the temp dir internally).
  Future<Uint8List?> removeBackgroundFromBytes(Uint8List imageBytes) =>
      NativeLooktokEngine.instance.extractSilhouette(imageBytes);
}
