import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';

import '../theme.dart';

/// Premium full-screen overlay while a wardrobe item uploads + isolates.
/// Shown via showDialog with a transparent barrier: blurred dark backdrop, a
/// central circle bordered by a thin progress ring, editorial copy below, and
/// a Cancel pill at the bottom.
///
/// LOTTIE SLOT: the circle is built to host `Lottie.asset('assets/hanger_reveal.json')`
/// once the asset + `lottie` package land — swap `_PulsingHanger` for it. Until
/// then the fallback is a softly pulsing hanger icon (no extra dependency).
class PremiumWardrobeLoader extends StatelessWidget {
  const PremiumWardrobeLoader({super.key, required this.onCancel});
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Blurred, darkened glass over the whole screen.
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: const ColoredBox(color: Color(0x99000000)),
        ),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Central circle + perfectly bordering thin progress ring.
            SizedBox(
              width: 248,
              height: 248,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const SizedBox(
                    width: 248,
                    height: 248,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                  ClipOval(
                    child: Container(
                      width: 224,
                      height: 224,
                      color: Colors.white,
                      // ← Lottie.asset('assets/hanger_reveal.json') goes here.
                      child: const _PulsingHanger(),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            const Text('Adding to Wardrobe…',
                style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -0.4, decoration: TextDecoration.none)),
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text('This might take a moment.',
                  style: TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.w400, decoration: TextDecoration.none)),
            ),
          ],
        ),
        // Bottom: dark pill — cancel.
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: GestureDetector(
                onTap: onCancel,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                  decoration: BoxDecoration(
                    color: const Color(0xE61A1A1A),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.close, size: 16, color: Colors.white),
                    SizedBox(width: 8),
                    Text('Cancel loading',
                        style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Fallback animation until the Lottie asset ships: a hanger softly pulsing in
/// scale + opacity on the white circle.
class _PulsingHanger extends StatefulWidget {
  const _PulsingHanger();
  @override
  State<_PulsingHanger> createState() => _PulsingHangerState();
}

class _PulsingHangerState extends State<_PulsingHanger> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final t = Curves.easeInOut.transform(_c.value);
        return Center(
          child: Opacity(
            opacity: 0.55 + 0.45 * t,
            child: Transform.scale(
              scale: 0.92 + 0.10 * t,
              child: const Icon(Icons.checkroom, size: 72, color: AppColors.ink),
            ),
          ),
        );
      },
    );
  }
}
