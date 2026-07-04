import 'package:flutter/material.dart';

enum SilhouetteKind { fullBody, face }

/// Dimmed scrim with a transparent silhouette cutout that guides the user to
/// position themselves correctly before capture (SDD §3.7). Pure paint — no
/// image assets, so it scales crisply on every device.
class SilhouetteOverlay extends StatelessWidget {
  const SilhouetteOverlay({super.key, required this.kind});
  final SilhouetteKind kind;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(size: Size.infinite, painter: _SilhouettePainter(kind)),
    );
  }
}

class _SilhouettePainter extends CustomPainter {
  _SilhouettePainter(this.kind);
  final SilhouetteKind kind;

  @override
  void paint(Canvas canvas, Size size) {
    final scrim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final cutout = kind == SilhouetteKind.fullBody
        ? _bodyPath(size)
        : _facePath(size);

    // Punch the silhouette out of the scrim.
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(Offset.zero & size, scrim);
    canvas.drawPath(cutout, Paint()..blendMode = BlendMode.clear);
    canvas.restore();

    // Dashed guide stroke around the cutout.
    canvas.drawPath(
      cutout,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF2F5BEA), // cobalt accent
    );
  }

  Path _facePath(Size s) {
    final r = s.width * 0.34;
    return Path()
      ..addOval(Rect.fromCenter(
        center: Offset(s.width / 2, s.height * 0.4),
        width: r * 2,
        height: r * 2.5,
      ));
  }

  Path _bodyPath(Size s) {
    // Simple head + tapered torso/legs capsule centered in frame.
    final cx = s.width / 2;
    final headR = s.width * 0.09;
    final top = s.height * 0.12;
    final path = Path()
      ..addOval(Rect.fromCircle(center: Offset(cx, top + headR), radius: headR));
    final bodyTop = top + headR * 2.1;
    final bodyRect = Rect.fromLTRB(
      cx - s.width * 0.20,
      bodyTop,
      cx + s.width * 0.20,
      s.height * 0.9,
    );
    path.addRRect(RRect.fromRectAndRadius(bodyRect, const Radius.circular(60)));
    return path;
  }

  @override
  bool shouldRepaint(covariant _SilhouettePainter old) => old.kind != kind;
}
