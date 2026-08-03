import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'status_cycler.dart';

/// "Review my outfit" loading state — the user's OWN photo full-screen with a
/// dark overlay and an elegant scanning line sweeping up and down, plus AI
/// status lines cycling every 2s. Reads as "the stylist is examining YOUR
/// photo" instead of showing unrelated stock imagery.
class ScanLoader extends StatefulWidget {
  const ScanLoader({super.key, required this.image, required this.messages});
  final Uint8List image;
  final List<String> messages;

  @override
  State<ScanLoader> createState() => _ScanLoaderState();
}

class _ScanLoaderState extends State<ScanLoader> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        Image.memory(widget.image, fit: BoxFit.contain, gaplessPlayback: true),
        // Dark veil so the scan line + copy read clearly (~45%).
        const ColoredBox(color: Color(0x73000000)),
        // The scanning line — thin, luminous, easing top <-> bottom.
        AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = Curves.easeInOut.transform(_c.value);
            return Align(
              alignment: Alignment(0, t * 2 - 1),
              child: Container(
                height: 1.6,
                margin: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    AppColors.signature.withValues(alpha: 0),
                    Colors.white,
                    AppColors.signature.withValues(alpha: 0),
                  ]),
                  boxShadow: [
                    BoxShadow(color: AppColors.signature.withValues(alpha: 0.55), blurRadius: 14, spreadRadius: 1),
                  ],
                ),
              ),
            );
          },
        ),
        // AI thoughts — lower third, cycling every 2s.
        Align(
          alignment: const Alignment(0, 0.72),
          child: SizedBox(
            height: 22,
            child: StatusCycler(
              phrases: widget.messages,
              interval: const Duration(seconds: 2),
              style: const TextStyle(
                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 1.6),
            ),
          ),
        ),
      ],
    );
  }
}
