import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:video_player/video_player.dart';

/// Who the mannequin loop is rendered for.
enum LoaderGender {
  male,
  female;

  /// Map the backend's `gender_presentation` (masculine/feminine/neutral)
  /// onto an asset variant. Neutral/unknown falls back to [male] — the loops
  /// are abstract mannequins, not portraits.
  static LoaderGender fromPresentation(String? presentation) =>
      (presentation ?? '').toLowerCase().contains('fem')
          ? LoaderGender.female
          : LoaderGender.male;
}

/// Which garment category the mannequin is putting on.
enum LoaderCategory {
  top,
  bottom,
  shoes,
  accessories;

  /// Editor slot name → category ('bottom', 'bottoms', 'outerwear' → sane
  /// buckets). Unknown slots read as [top] — the most universal loop.
  static LoaderCategory fromSlot(String? slot) => switch ((slot ?? '').toLowerCase()) {
        'bottom' || 'bottoms' || 'pants' || 'trousers' => LoaderCategory.bottom,
        'shoes' || 'footwear' => LoaderCategory.shoes,
        'accessories' || 'accessory' => LoaderCategory.accessories,
        _ => LoaderCategory.top,
      };
}

/// Pre-rendered mannequin dressing loop, blended over the app UI.
///
/// The loops are exported on an ABSOLUTE #000000 background; BlendMode.screen
/// keeps every lit pixel and drops pure black to transparent, so the glowing
/// mannequin floats over whatever sits underneath — no chroma keying, no
/// alpha-channel video needed.
///
/// Asset convention (drop files in `assets/videos/`, no code changes needed):
///   assets/videos/[gender]_[category]_loop.mp4
///   e.g. assets/videos/male_top_loop.mp4, assets/videos/female_shoes_loop.mp4
///
/// Fault-tolerant by design: a missing/corrupt asset NEVER breaks the screen —
/// [onUnavailable] fires once and the widget renders nothing, letting the
/// caller keep its existing loader (the StyleScanner scene).
class LooktokVideoLoader extends StatefulWidget {
  const LooktokVideoLoader({
    super.key,
    required this.gender,
    required this.category,
    this.dismissed = false,
    this.onDismissed,
    this.onUnavailable,
    this.onReady,
    this.showFallback = true,
  });

  final LoaderGender gender;
  final LoaderCategory category;

  /// Flip to true to fade the loop out gracefully; [onDismissed] fires when
  /// the fade completes (then remove the widget from the tree).
  final bool dismissed;
  final VoidCallback? onDismissed;

  /// Called once if the asset for this gender×category doesn't exist or fails
  /// to decode — the caller should show its fallback loader instead.
  final VoidCallback? onUnavailable;

  /// Called once when the loop is decoded and playing (first real frame).
  final VoidCallback? onReady;

  /// Subtle pulse while the asset loads into memory (a few ms). Disable when
  /// the caller already renders its own scene underneath.
  final bool showFallback;

  String get assetPath =>
      'assets/videos/${gender.name}_${category.name}_loop.mp4';

  @override
  State<LooktokVideoLoader> createState() => _LooktokVideoLoaderState();
}

class _LooktokVideoLoaderState extends State<LooktokVideoLoader>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _unavailable = false;

  late final AnimationController _fade = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 380));

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Cheap existence probe FIRST: a missing asset throws inside the native
    // player with an ugly platform error — rootBundle fails fast and clean.
    try {
      await rootBundle.load(widget.assetPath);
    } catch (_) {
      _bail();
      return;
    }
    final c = VideoPlayerController.asset(widget.assetPath);
    _controller = c;
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.setVolume(0);
      await c.play();
      if (!mounted) return;
      setState(() => _ready = true);
      _fade.forward();
      widget.onReady?.call();
    } catch (_) {
      _bail();
    }
  }

  void _bail() {
    if (!mounted) return;
    setState(() => _unavailable = true);
    widget.onUnavailable?.call();
  }

  @override
  void didUpdateWidget(covariant LooktokVideoLoader old) {
    super.didUpdateWidget(old);
    if (widget.dismissed && !old.dismissed) {
      _fade.reverse().whenComplete(() {
        if (mounted) widget.onDismissed?.call();
      });
    }
  }

  @override
  void dispose() {
    // Strict lifecycle: the native player dies WITH the widget — no leaked
    // decoders, no audio-session residue.
    _controller?.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_unavailable) return const SizedBox.shrink();
    if (!_ready) {
      // The few ms while the loop decodes: a quiet pulse, never a black hole.
      return widget.showFallback
          ? const Center(child: CupertinoActivityIndicator(radius: 11))
          : const SizedBox.shrink();
    }
    final c = _controller!;
    return IgnorePointer(
      child: FadeTransition(
        opacity: CurvedAnimation(parent: _fade, curve: Curves.easeOut),
        // screen-blend: out = 1 − (1−dst)·(1−src) → pure-black src pixels
        // leave dst untouched (transparent), lit pixels add glow.
        child: ColorFiltered(
          colorFilter: const ColorFilter.mode(Colors.black, BlendMode.screen),
          child: Center(
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio == 0 ? 3 / 4 : c.value.aspectRatio,
              child: VideoPlayer(c),
            ),
          ),
        ),
      ),
    );
  }
}
