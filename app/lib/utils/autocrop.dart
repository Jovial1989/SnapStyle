import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Trim the studio backdrop around the person so the figure fills the frame on a
/// clean white backing. The subject is detected by EDGES (local gradient), plus
/// colour and darkness — so it catches a white sneaker on white (it has an
/// outline/shadow) and coloured/dark clothing, while ignoring a smooth
/// grey/white backdrop or spotlight vignette (near-zero gradient, desaturated).
/// Builds row/column content profiles, ignores stray specks, and — because a
/// full-body render's feet sit at the very bottom — extends the crop to the
/// bottom edge when content reaches the lower band, so shoes are never cut.
/// Runs in an isolate via `compute`. Returns the input unchanged on no subject.
Uint8List autoCropSubject(Uint8List bytes) {
  final src = img.decodeImage(bytes);
  if (src == null) return bytes;
  final w = src.width, h = src.height;
  if (w < 16 || h < 16) return bytes;

  final step = (w * h > 250000) ? 2 : 1;
  final colCount = List<int>.filled(w, 0);
  final rowCount = List<int>.filled(h, 0);
  const gThresh = 22; // luminance gradient that marks an edge
  const sThresh = 0.16; // saturation
  const vThresh = 0.32; // darkness (value)

  double lum(img.Pixel p) => 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;

  for (var y = 0; y < h; y += step) {
    for (var x = 0; x < w; x += step) {
      final p = src.getPixel(x, y);
      final r = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
      final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
      final sat = mx <= 0 ? 0.0 : (mx - mn) / mx;
      final val = mx / 255.0;
      var content = sat > sThresh || val < vThresh;
      if (!content) {
        final l = lum(p);
        final gx = x + step < w ? (l - lum(src.getPixel(x + step, y))).abs() : 0.0;
        final gy = y + step < h ? (l - lum(src.getPixel(x, y + step))).abs() : 0.0;
        if (gx + gy > gThresh) content = true;
      }
      if (content) {
        colCount[x]++;
        rowCount[y]++;
      }
    }
  }

  final minCol = ((h / step) * 0.01).ceil().clamp(2, 9999);
  final minRow = ((w / step) * 0.01).ceil().clamp(2, 9999);
  int minX = -1, maxX = -1, minY = -1, maxY = -1;
  for (var x = 0; x < w; x++) {
    if (colCount[x] >= minCol) {
      if (minX < 0) minX = x;
      maxX = x;
    }
  }
  for (var y = 0; y < h; y++) {
    if (rowCount[y] >= minRow) {
      if (minY < 0) minY = y;
      maxY = y;
    }
  }
  if (minX < 0 || minY < 0 || maxX <= minX || maxY <= minY) return bytes;

  final padX = (w * 0.04).round(), padY = (h * 0.04).round();
  minX = (minX - padX).clamp(0, w - 1);
  maxX = (maxX + padX).clamp(0, w - 1);
  minY = (minY - padY).clamp(0, h - 1);
  // FULL-BODY GUARANTEE: every caller feeds head-to-toe frames, and pale
  // shins/light shoes on white have now fooled TWO generations of detection
  // heuristics (the avatar kept getting cut at the shins). The bottom edge —
  // feet, shoes, floor shadow — is simply NEVER trimmed. The sub-percent of
  // extra white margin is invisible on the studio backdrop.
  maxY = h - 1;

  final cw = maxX - minX + 1, ch = maxY - minY + 1;
  if (cw >= w * 0.97 && ch >= h * 0.97) return bytes;

  final cropped = img.copyCrop(src, x: minX, y: minY, width: cw, height: ch);

  // Snap the near-white studio backdrop to PURE white so it never reads grey.
  // Only very bright, desaturated pixels are lifted — garments (which have
  // colour or shadow/edges below this brightness) are untouched.
  for (final p in cropped) {
    final r = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
    final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
    final sat = mx <= 0 ? 0.0 : (mx - mn) / mx;
    if (mx >= 236 && sat < 0.06) p.setRgb(255, 255, 255);
  }

  return Uint8List.fromList(img.encodeJpg(cropped, quality: 88));
}

/// Head crop for the FACE IDENTITY ANCHOR: the top-center band of a
/// head-to-toe frame (portrait framing puts the head there deterministically).
/// Sent as the LAST reference image on every swap so the model copies THIS
/// face instead of inventing a person. Runs in an isolate via `compute`.
Uint8List headCrop(Uint8List bytes) {
  final src = img.decodeImage(bytes);
  if (src == null) return bytes;
  final w = src.width, h = src.height;
  if (w < 32 || h < 32) return bytes;
  final cw = (w * 0.52).round();
  final ch = (h * 0.24).round();
  final c = img.copyCrop(src, x: ((w - cw) / 2).round(), y: 0, width: cw, height: ch);
  final r = c.width > 320 ? img.copyResize(c, width: 320) : c;
  return Uint8List.fromList(img.encodeJpg(r, quality: 85));
}

/// TRUE when the figure runs off the bottom edge of a render (cut-off feet).
/// A proper full-body studio render always leaves a white margin below the
/// shoes; content touching the bottom rows means the model zoomed in. Pure
/// pixel arithmetic — the model-based QA missed this class three times.
bool feetCutOff(Uint8List bytes) {
  final src = img.decodeImage(bytes);
  if (src == null) return false;
  final w = src.width, h = src.height;
  if (w < 32 || h < 32) return false;
  var contentCols = 0;
  final band = (h * 0.015).clamp(2, 8).round();
  for (var x = 0; x < w; x += 2) {
    var hit = false;
    for (var y = h - band; y < h && !hit; y++) {
      final p = src.getPixel(x, y);
      final r = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
      final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
      final sat = mx <= 0 ? 0.0 : (mx - mn) / mx;
      // Solid content only — soft floor shadows stay above 0.80 brightness.
      if (mx / 255.0 < 0.80 || sat > 0.14) hit = true;
    }
    if (hit) contentCols++;
  }
  return contentCols > (w / 2) * 0.10; // >10% of sampled columns = legs, not specks
}

/// Composite a (possibly TRANSPARENT) cutout onto an opaque WHITE canvas and
/// return JPEG bytes. Sending Gemini a transparent PNG/WebP silhouette was the
/// root of two bugs: matte-fringe HALOS the model left when "rebuilding the
/// white background" around the alpha edge, and outright `IMAGE_OTHER` refusals
/// (the image model handles opaque input far more reliably than alpha). A flat
/// white-backed JPEG gives it nothing to hallucinate around. Runs in an isolate
/// via `compute`. Returns the input unchanged if it can't be decoded.
Uint8List flattenOnWhite(Uint8List bytes) {
  final src = img.decodeImage(bytes);
  if (src == null) return bytes;
  // Already opaque (no alpha channel) → no flattening needed; still re-encode
  // to JPEG so the payload carries no alpha and stays deterministic.
  final canvas = img.Image(width: src.width, height: src.height, numChannels: 3);
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(canvas, src); // src alpha blended over white
  return img.encodeJpg(canvas, quality: 92);
}

/// UNIFORM item-thumbnail framing. Library flat-lays were shown as-is (varied,
/// often edge-tight) while Gemini item renders were autocropped flush — so the
/// hanger cards read as "all different, some cut at the sides". This trims the
/// white/transparent margin to the garment's bounding box, then re-centers it on
/// a SQUARE white canvas with a fixed ~10% margin. Every item — whatever the
/// source — ends up identically framed, never side-cropped. Isolate-safe;
/// returns the input unchanged if it can't decode or is effectively blank.
Uint8List normalizeItemThumb(Uint8List bytes) {
  final src = img.decodeImage(bytes);
  if (src == null) return bytes;
  final w = src.width, h = src.height;
  if (w < 8 || h < 8) return bytes;
  final step = (w * h > 300000) ? 2 : 1;
  int minX = w, minY = h, maxX = -1, maxY = -1;
  for (var y = 0; y < h; y += step) {
    for (var x = 0; x < w; x += step) {
      final p = src.getPixel(x, y);
      final nearWhite = p.r > 244 && p.g > 244 && p.b > 244;
      if (p.a < 16 || nearWhite) continue; // background (transparent or white)
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  if (maxX < minX || maxY < minY) return bytes; // all background → leave as-is
  final bw = maxX - minX + 1, bh = maxY - minY + 1;
  final content = bw > bh ? bw : bh;
  final side = (content * 1.20).round(); // ~10% margin each side
  final canvas = img.Image(width: side, height: side, numChannels: 3);
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  final cropped = img.copyCrop(src, x: minX, y: minY, width: bw, height: bh);
  final dx = ((side - bw) / 2).round(), dy = ((side - bh) / 2).round();
  img.compositeImage(canvas, cropped, dstX: dx, dstY: dy);
  return img.encodeJpg(canvas, quality: 90);
}

/// Key out the white studio backdrop of a flat-lay so the garment can sit
/// DIRECTLY on the avatar as a paper-doll cutout (no white card). Border-
/// connected flood fill over progressively softer "near-white" thresholds
/// (JPEG whites and floor shadows are rarely a clean 255) with a saturation
/// guard so beige/cream garments survive. One erosion pass de-halos the edge.
/// Returns PNG with alpha, or an EMPTY list when the image can't be keyed —
/// the caller falls back to a card presentation. Isolate-safe.
Uint8List cutoutItemThumb(Uint8List bytes) {
  final src = img.decodeImage(bytes);
  if (src == null) return Uint8List(0);
  final w = src.width, h = src.height;
  if (w < 8 || h < 8) return Uint8List(0);
  final base = src.convert(numChannels: 4);
  final total = w * h;

  for (final t in const [243, 234, 226]) {
    final rgba = img.Image.from(base);
    final bg = Uint8List(total);
    final stack = <int>[];
    bool isBg(int x, int y) {
      final p = rgba.getPixel(x, y);
      final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
      final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
      return mn >= t && (mx - mn) <= 18; // bright AND desaturated = backdrop
    }
    void seed(int x, int y) {
      final i = y * w + x;
      if (bg[i] == 0 && isBg(x, y)) { bg[i] = 1; stack.add(i); }
    }
    for (var x = 0; x < w; x++) { seed(x, 0); seed(x, h - 1); }
    for (var y = 0; y < h; y++) { seed(0, y); seed(w - 1, y); }
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      final x = i % w, y = i ~/ w;
      if (x > 0) seed(x - 1, y);
      if (x < w - 1) seed(x + 1, y);
      if (y > 0) seed(x, y - 1);
      if (y < h - 1) seed(x, y + 1);
    }
    var keyed = 0;
    for (var i = 0; i < total; i++) { if (bg[i] == 1) keyed++; }
    // Barely anything keyed → the backdrop is darker than this threshold; try
    // the softer one. (A flat-lay's backdrop is a large share of the frame.)
    if (keyed < total * 0.10) continue;
    // The pass ATE the garment (light item + soft threshold) → unkeyable.
    if (total - keyed < total * 0.04) break;

    var minX = w, minY = h, maxX = -1, maxY = -1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (bg[y * w + x] == 1) {
          rgba.getPixel(x, y).a = 0;
        } else {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < minX) continue;
    // De-halo: opaque near-white pixels touching transparency are JPEG fringe.
    final fringe = <int>[];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        if (bg[i] == 1) continue;
        final touching = (x > 0 && bg[i - 1] == 1) || (x < w - 1 && bg[i + 1] == 1) ||
            (y > 0 && bg[i - w] == 1) || (y < h - 1 && bg[i + w] == 1);
        if (!touching) continue;
        final p = rgba.getPixel(x, y);
        final mn = [p.r.toInt(), p.g.toInt(), p.b.toInt()].reduce((a, b) => a < b ? a : b);
        if (mn >= 214) fringe.add(i);
      }
    }
    for (final i in fringe) { rgba.getPixel(i % w, i ~/ w).a = 0; }
    final pad = ((maxX - minX) * 0.03).round().clamp(1, 16);
    final cropped = img.copyCrop(
      rgba,
      x: (minX - pad).clamp(0, w - 1),
      y: (minY - pad).clamp(0, h - 1),
      width: (maxX - minX + 1 + pad * 2).clamp(1, w),
      height: (maxY - minY + 1 + pad * 2).clamp(1, h),
    );
    return img.encodePng(cropped);
  }
  return Uint8List(0); // unkeyable — caller shows a compact card instead
}
