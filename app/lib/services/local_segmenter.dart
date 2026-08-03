import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// On-device silhouette isolation (Edge AI) — zero server round-trip, zero
/// per-image cost. ML Kit selfie segmentation produces a person-confidence
/// mask; pure-Dart compositing (in an isolate) turns it into the SAME output
/// contract the remote rembg service had: a 512×512 transparent PNG with the
/// subject centered. Callers can therefore swap between local and remote
/// isolation without touching anything downstream.
///
/// Note: the brief's `google_mlkit_subject_segmentation` is Android-only beta;
/// selfie segmentation is the stable cross-platform equivalent (iOS 15.5+).
class LocalSegmenter {
  LocalSegmenter._();
  static final LocalSegmenter instance = LocalSegmenter._();

  // single mode = highest-quality static-photo model (stream mode trades
  // accuracy for video frame rate, which we don't need).
  final _segmenter = SelfieSegmenter(mode: SegmenterMode.single);

  /// Serializes access: one native segmenter instance must not run overlapping
  /// requests (compare sends 2–4 photos at once).
  Future<void> _queue = Future.value();

  /// Isolate the person in [bytes] → 512×512 transparent PNG (also written to
  /// the temp dir for inspection). Throws when the device/model can't produce
  /// a usable mask — callers decide the fallback.
  Future<Uint8List> isolate(Uint8List bytes) {
    final job = _queue.then((_) => _isolate(bytes));
    // Keep the queue alive even when a job fails (errors surface to the caller).
    _queue = job.then((_) {}, onError: (_) {});
    return job;
  }

  Future<Uint8List> _isolate(Uint8List bytes) async {
    // ML Kit reads files (fromBytes accepts only raw camera formats) — stage
    // the JPEG in the temp dir, and drop the PNG result next to it.
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final src = File('${dir.path}/seg-$stamp-src.jpg');
    await src.writeAsBytes(bytes, flush: true);
    try {
      final mask = await _segmenter.processImage(InputImage.fromFilePath(src.path));
      if (mask == null || mask.confidences.isEmpty) {
        throw StateError('segmentation produced no mask');
      }
      final png = await compute(
        _composite,
        _CompositeJob(bytes, mask.width, mask.height, mask.confidences),
      );
      await File('${dir.path}/seg-$stamp-out.png').writeAsBytes(png, flush: true);
      return png;
    } finally {
      src.delete().then((_) {}, onError: (_) {});
    }
  }

  void close() => _segmenter.close();
}

class _CompositeJob {
  const _CompositeJob(this.bytes, this.maskWidth, this.maskHeight, this.confidences);
  final Uint8List bytes;
  final int maskWidth;
  final int maskHeight;
  final List<double> confidences;
}

/// Isolate entry: original JPEG + confidence mask → cropped, padded 512×512
/// transparent PNG (mirrors the rembg service output exactly).
Uint8List _composite(_CompositeJob job) {
  final srcImg = img.decodeImage(job.bytes);
  if (srcImg == null) throw StateError('undecodable image');
  final w = srcImg.width, h = srcImg.height;

  // Confidence → alpha with a feathered edge (hard cut below 0.35, solid above
  // 0.62, smooth ramp between) — soft hair/shoulder edges, no halo.
  final cut = img.Image(width: w, height: h, numChannels: 4);
  final sx = job.maskWidth / w, sy = job.maskHeight / h;
  var minX = w, minY = h, maxX = -1, maxY = -1;
  for (var y = 0; y < h; y++) {
    final my = (y * sy).floor().clamp(0, job.maskHeight - 1) * job.maskWidth;
    for (var x = 0; x < w; x++) {
      final c = job.confidences[my + (x * sx).floor().clamp(0, job.maskWidth - 1)];
      final a = c <= 0.35 ? 0 : c >= 0.62 ? 255 : (((c - 0.35) / 0.27) * 255).round();
      if (a == 0) continue;
      final p = srcImg.getPixel(x, y);
      cut.setPixelRgba(x, y, p.r, p.g, p.b, a);
      if (a > 16) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  // A real person fills a meaningful share of the frame; a sliver means the
  // model found nothing useful — let the caller fall back.
  if (maxX < 0 || (maxX - minX) * (maxY - minY) < w * h * 0.02) {
    throw StateError('no subject found');
  }

  final cropped = img.copyCrop(cut,
      x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1);
  // 1024 (was 512): compare cards show these full screen — 512 upscaled to a
  // ~2400px paint target is visibly soft. The native iOS path already returns
  // full-resolution cutouts; this keeps the ML Kit fallback comparable.
  const size = 1024;
  final scale = size / (cropped.width > cropped.height ? cropped.width : cropped.height);
  final resized = img.copyResize(cropped,
      width: (cropped.width * scale).round().clamp(1, size),
      height: (cropped.height * scale).round().clamp(1, size),
      interpolation: img.Interpolation.linear);
  final canvas = img.Image(width: size, height: size, numChannels: 4); // transparent
  img.compositeImage(canvas, resized,
      dstX: (size - resized.width) ~/ 2, dstY: (size - resized.height) ~/ 2);
  return img.encodePng(canvas, level: 6);
}
