import 'dart:async';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';

import 'status_cycler.dart';

/// "Generate today's look" loading state — an ambient MOODBOARD: reference
/// looks matching the chosen occasion slowly crossfade behind a blur + dark
/// overlay, with a sleek central indicator and AI thoughts cycling every 2s.
/// The imagery sets the mood; it never reads as the result itself.
class MoodboardLoader extends StatefulWidget {
  const MoodboardLoader({super.key, required this.images, required this.occasion, required this.thoughts});
  /// Resolves to feed items `{url, ...}` (occasion-matched muses). Empty → plain dark.
  final Future<List<Map<String, dynamic>>> images;
  final String occasion;
  final List<String> thoughts;

  @override
  State<MoodboardLoader> createState() => _MoodboardLoaderState();
}

class _MoodboardLoaderState extends State<MoodboardLoader> {
  List<String> _urls = const [];
  int _i = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.images.then((items) {
      if (!mounted) return;
      setState(() => _urls = [for (final it in items) (it['url'] ?? '').toString()]..removeWhere((u) => u.isEmpty));
      if (_urls.length > 1) {
        _timer = Timer.periodic(const Duration(milliseconds: 3600), (_) {
          if (mounted) setState(() => _i = (_i + 1) % _urls.length);
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF0A0A0A)),
        // Ambient moodboard: blurred, veiled, slowly crossfading references.
        if (_urls.isNotEmpty)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 900),
            child: Image.network(_urls[_i], key: ValueKey(_urls[_i]), fit: BoxFit.cover, gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink()),
          ),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 9, sigmaY: 9),
          child: const ColoredBox(color: Color(0x73000000)), // ~45% veil
        ),
        // Center: occasion + sleek ring + cycling AI thoughts.
        SafeArea(
          child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('STYLING · ${widget.occasion.toUpperCase()}',
                style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 2.4)),
            const SizedBox(height: 26),
            const SizedBox(
              width: 46, height: 46,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: Colors.white),
            ),
            const SizedBox(height: 26),
            SizedBox(
              height: 22,
              child: StatusCycler(
                phrases: widget.thoughts,
                interval: const Duration(seconds: 2),
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 1.2),
              ),
            ),
          ],
        ),
        ),
      ],
    );
  }
}

