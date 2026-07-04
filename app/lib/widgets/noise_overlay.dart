import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';

/// Near-invisible monochrome noise overlay (~2% opacity) for a premium tactile
/// surface. Painted once (stable seed, shouldRepaint=false) and layered above
/// everything via MaterialApp.builder as an IgnorePointer.
class NoiseOverlay extends StatelessWidget {
  const NoiseOverlay({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(child: CustomPaint(painter: _NoisePainter())),
        ),
      ],
    );
  }
}

class _NoisePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rnd = Random(7); // fixed seed → stable grain
    final count = (size.width * size.height / 900).clamp(400, 6000).toInt();
    final points = List<Offset>.generate(
      count,
      (_) => Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height),
    );
    canvas.drawPoints(
      PointMode.points,
      points,
      Paint()
        ..color = const Color(0x08000000) // ~3% black
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _NoisePainter oldDelegate) => false;
}
