import 'package:flutter/material.dart';

import '../theme.dart';

/// Lightweight hand-rolled shimmer (no extra dependency). Wrap skeleton blocks
/// in [Shimmer]; use [ShimmerBox] for the blocks themselves (SDD §3.8).
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment(-1 - 2 * t, 0),
            end: Alignment(1 - 2 * t, 0),
            colors: const [Color(0x11000000), Color(0x33FFFFFF), Color(0x11000000)],
            stops: const [0.35, 0.5, 0.65],
          ).createShader(bounds),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class ShimmerBox extends StatelessWidget {
  const ShimmerBox({super.key, this.height = 16, this.width = double.infinity, this.radius = 8});
  final double height;
  final double width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
