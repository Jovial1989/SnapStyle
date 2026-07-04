import 'package:flutter/material.dart';
import '../theme.dart';

/// Brand mark — minimalist mobile-camera **focus crop-marks** framing a clean
/// lens, with a single signature-blue **AI lens pupil**. Strictly scalable: only
/// thick rounded strokes and solid shapes, no ticks or hairlines (SDD §9.1).
class LensMark extends StatelessWidget {
  const LensMark({super.key, this.size = 26, this.color = AppColors.ink});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _MarkPainter(color));
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.10
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Four camera focus crop-marks (⌜ ⌝ ⌞ ⌟).
    final inset = w * 0.12;
    final len = w * 0.22;
    void bracket(double cx, double cy, double dx, double dy) {
      canvas.drawPath(
        Path()
          ..moveTo(cx + dx * len, cy)
          ..lineTo(cx, cy)
          ..lineTo(cx, cy + dy * len),
        line,
      );
    }

    bracket(inset, inset, 1, 1); // TL
    bracket(w - inset, inset, -1, 1); // TR
    bracket(inset, w - inset, 1, -1); // BL
    bracket(w - inset, w - inset, -1, -1); // BR

    // Clean lens + single blue AI pupil.
    final c = Offset(w / 2, w / 2);
    canvas.drawCircle(c, w * 0.20, Paint()..color = color); // solid black lens
    canvas.drawCircle(c, w * 0.085, Paint()..color = AppColors.signature); // AI pupil
  }

  @override
  bool shouldRepaint(covariant _MarkPainter old) => old.color != color;
}

/// `snapstyle` wordmark — split weight (heavy "snap" + light "style"), tightly
/// tracked. Dependency-free (reverted from the Baloo 2 experiment).
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.size = 22, this.color = AppColors.ink});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w700,
          letterSpacing: -size * 0.045,
          color: color,
          height: 1.0,
        ),
        children: [
          const TextSpan(text: 'snap'),
          TextSpan(text: 'style', style: TextStyle(fontWeight: FontWeight.w300, color: color)),
        ],
      ),
    );
  }
}

/// Full lockup: mark + wordmark.
class Logo extends StatelessWidget {
  const Logo({super.key, this.size = 22, this.color = AppColors.ink});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LensMark(size: size * 1.25, color: color),
        SizedBox(width: size * 0.4),
        Wordmark(size: size, color: color),
      ],
    );
  }
}
