import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme.dart';
import 'status_cycler.dart';

/// The one loader used across the app while AI work runs — a soft cobalt sweep
/// ring around a figure with rotating status lines. Keeping it identical
/// everywhere (analyze, editor prep) means the user sees a single
/// continuous loader, never a jarring switch between styles.
class StylingLoader extends StatefulWidget {
  const StylingLoader({super.key, required this.messages, this.footer});
  final List<String> messages;

  /// Optional content shown below the ring (e.g. a [LoaderFeed] of looks) while
  /// the work runs. When null the loader is exactly as before — just the ring.
  final Widget? footer;
  @override
  State<StylingLoader> createState() => _StylingLoaderState();
}

class _StylingLoaderState extends State<StylingLoader> with SingleTickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.footer == null) return Center(child: _core());
    // With a feed: keep the ring block centered in the upper region, seat the
    // feed at the bottom so it reads as "…and here's inspiration while you wait".
    return Column(
      children: [
        Expanded(child: Center(child: _core())),
        widget.footer!,
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _core() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 236,
          height: 236,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.all(26),
                child: Opacity(
                  opacity: 0.9,
                  child: ClipOval(child: Image.asset('assets/onboarding/selfie.jpg', fit: BoxFit.contain)),
                ),
              ),
              AnimatedBuilder(
                animation: _spin,
                builder: (_, _) => CustomPaint(painter: _RingPainter(_spin.value), size: const Size.square(236)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 40),
        SizedBox(height: 28, child: StatusCycler(phrases: widget.messages, style: AppType.h2)),
        const SizedBox(height: 10),
        const Text('This takes a few seconds',
            style: TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.4)),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.t);
  final double t;
  static const _blue = AppColors.signature;
  @override
  void paint(Canvas canvas, Size s) {
    final c = Offset(s.width / 2, s.height / 2);
    final r = s.width / 2 - 4;
    canvas.drawCircle(
      c, r,
      Paint()
        ..color = AppColors.line.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6,
    );
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(t * 2 * math.pi);
    final rect = Rect.fromCircle(center: Offset.zero, radius: r);
    final arc = Paint()
      ..shader = SweepGradient(
        colors: [_blue.withValues(alpha: 0), _blue.withValues(alpha: 0.15), _blue],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 1.7, false, arc);
    final end = Offset(r * math.cos(math.pi * 1.7), r * math.sin(math.pi * 1.7));
    canvas.drawCircle(end, 5, Paint()..color = _blue);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.t != t;
}
