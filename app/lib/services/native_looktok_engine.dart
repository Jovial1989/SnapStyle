import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Direct bridge to platform-native hot paths (`com.looktok.app/engine`):
/// zero-lag camera capture and instant subject segmentation (Apple Vision on
/// iOS 17+, ML Kit subject segmentation on Android). Unlike the selfie-only
/// Flutter plugin, the native APIs cut out ANY salient subject — people AND
/// flat-laid garments — which is what the wardrobe flow needs.
///
/// Every method is fail-soft BY CONTRACT: any platform error, missing native
/// implementation (MissingPluginException — e.g. Android until its side ships)
/// or unsupported OS resolves to `null`, never throws. Callers treat `null` as
/// "use the fallback" (Flutter picker / ML Kit plugin / remote rembg).
///
/// Cross-channel payloads are FILE PATHS, not bytes — multi-MB images never
/// get copied through the platform codec. See NATIVE_ENGINE.md for the
/// Swift/Kotlin contract.
class NativeLooktokEngine {
  NativeLooktokEngine._();
  static final NativeLooktokEngine instance = NativeLooktokEngine._();

  static const _channel = MethodChannel('com.looktok.app/engine');

  bool? _segmentationSupported; // cached capability probe

  /// True when the OS can run native subject segmentation (iOS 17+ Vision /
  /// Android with the ML Kit subject-segmentation module installed).
  Future<bool> segmentationSupported() async {
    if (_segmentationSupported != null) return _segmentationSupported!;
    try {
      _segmentationSupported =
          await _channel.invokeMethod<bool>('isSegmentationSupported') ?? false;
    } catch (_) {
      _segmentationSupported = false;
    }
    return _segmentationSupported!;
  }

  /// Native full-quality camera capture (the platform camera UI, no Flutter
  /// texture round-trip). Returns JPEG bytes (long side ≤1600px, encoded
  /// native-side) — or null when cancelled, unavailable or not implemented.
  Future<Uint8List?> captureHighResPhoto() async {
    try {
      final path = await _channel.invokeMethod<String>('captureHighResPhoto');
      if (path == null) return null;
      final f = File(path);
      final bytes = await f.readAsBytes();
      f.delete().then((_) {}, onError: (_) {});
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  /// Instant on-device subject isolation → transparent PNG bytes (tight-cropped
  /// by the native side), or null when no confident subject was found or the
  /// device can't do it. Works on garments as well as people.
  Future<Uint8List?> extractSilhouette(Uint8List imageBytes) async {
    if (!await segmentationSupported()) return null;
    File? staged;
    try {
      final dir = await getTemporaryDirectory();
      staged = File(
          '${dir.path}/native-seg-${DateTime.now().microsecondsSinceEpoch}.jpg');
      await staged.writeAsBytes(imageBytes, flush: true);
      return await extractSilhouetteFromFile(staged.path);
    } catch (_) {
      return null;
    } finally {
      staged?.delete().then((_) {}, onError: (_) {});
    }
  }

  /// Same as [extractSilhouette], but for an image that ALREADY lives on disk
  /// (camera/picker files) — skips the redundant read + temp re-write.
  Future<Uint8List?> extractSilhouetteFromFile(String imagePath) async {
    if (!await segmentationSupported()) return null;
    try {
      final outPath = await _channel
          .invokeMethod<String>('extractSilhouette', {'imagePath': imagePath});
      if (outPath == null) return null;
      final out = File(outPath);
      final bytes = await out.readAsBytes();
      out.delete().then((_) {}, onError: (_) {});
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }
}
