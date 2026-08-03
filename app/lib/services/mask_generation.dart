import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../utils/webp_payload.dart';

/// Strategy contract for subject-mask generation: raw photo in → transparent
/// PNG silhouette out (the same output contract every engine in this app has
/// honored since the rembg service — callers never care who produced it).
///
/// Implementations must THROW on any failure; policy (timeouts, fallback,
/// circuit breaking) lives exclusively in [MaskGenerationController].
abstract class MaskGenerationStrategy {
  String get name;
  Future<Uint8List> generateMask(Uint8List image);
}

/// The engine that ships today — a thin adapter over the PROVEN cascade
/// (native Vision/ML Kit → selfie-segmentation plugin → remote rembg →
/// original bytes). The cascade itself stays where it lives; this stub only
/// gives it a seat in the strategy slot so the controller can fall back to it.
class LegacyMaskStrategy implements MaskGenerationStrategy {
  LegacyMaskStrategy(this._cascade);

  /// The existing, battle-tested isolation cascade (never throws by design —
  /// its own last resort is returning the original bytes).
  final Future<Uint8List> Function(Uint8List image) _cascade;

  @override
  String get name => 'legacy-cascade';

  @override
  Future<Uint8List> generateMask(Uint8List image) => _cascade(image);
}

/// EXPERIMENTAL: the Python CV worker (MediaPipe pose prompts + SAM 2 masks).
/// Enabled ONLY when the app is built with --dart-define=SAM2_ENGINE_URL=…;
/// with no URL the controller never even constructs the attempt — zero
/// behavior change for production builds.
class Sam2MaskStrategy implements MaskGenerationStrategy {
  static const engineUrl = String.fromEnvironment('SAM2_ENGINE_URL');
  static bool get configured => engineUrl.isNotEmpty;

  @override
  String get name => 'sam2-mediapipe';

  @override
  Future<Uint8List> generateMask(Uint8List image) async {
    // WebP q85 upload when the platform can encode it (alpha-safe, several
    // times lighter than PNG); extension/mime follow the ACTUAL bytes.
    final payload = await toWebPPayload(image);
    final req = http.MultipartRequest('POST', Uri.parse('$engineUrl/generate-mask'))
      ..files.add(http.MultipartFile.fromBytes('file', payload,
          filename: 'photo.${imageExt(payload)}'));
    // No internal timeout — the controller owns the deadline.
    final res = await req.send();
    if (res.statusCode != 200) {
      throw Exception('sam2 engine ${res.statusCode}');
    }
    final bytes = await res.stream.toBytes();
    if (bytes.isEmpty) throw Exception('sam2 engine returned no mask');
    return bytes;
  }
}

/// Runs the experimental engine FIRST under a strict deadline; any error,
/// non-200 or timeout falls through — seamlessly and silently — to the legacy
/// strategy. A session circuit breaker stops paying the deadline tax once the
/// experimental engine has proven dead (3 consecutive strikes), so a downed
/// worker costs at most ~9s across a whole session, not 3s per photo.
class MaskGenerationController {
  MaskGenerationController({
    required MaskGenerationStrategy legacy,
    MaskGenerationStrategy? experimental,
    Future<bool> Function()? gate,
    this.deadline = const Duration(seconds: 3),
  })  : _legacy = legacy,
        _experimental = experimental,
        _gate = gate;

  final MaskGenerationStrategy _legacy;
  final MaskGenerationStrategy? _experimental;

  /// Live kill-switch consulted per call (feature flag + dev override). The
  /// gate impl caches, so this is a memory read, not a network hop. Gate
  /// errors read as "off" — the experimental path must never break a photo.
  final Future<bool> Function()? _gate;
  final Duration deadline;

  static const _maxStrikes = 3;
  int _strikes = 0;

  Future<bool> _gateOpen() async {
    if (_gate == null) return true;
    try {
      return await _gate();
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List> generateMask(Uint8List image) async {
    final experimental = _experimental;
    if (experimental != null && _strikes < _maxStrikes && await _gateOpen()) {
      try {
        final out = await experimental.generateMask(image).timeout(deadline);
        _strikes = 0; // a success re-arms the breaker
        return out;
      } catch (_) {
        _strikes++; // timeout, transport error, non-200 — all count
      }
    }
    return _legacy.generateMask(image);
  }
}
