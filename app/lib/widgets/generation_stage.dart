import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'looktok_video_loader.dart';

/// The VTON wait, as a strict state machine with cinematic cross-fades.
///
///   analyzing  → blurred photo + a black veil tweening 0 → 0.7 (eye prep)
///                + a wide volumetric scanner band (no 1px lines)
///   rendering  → the veil dissolves into the TRUE black of the Veo mannequin
///                loop (pre-initialized during `analyzing` → zero buffering)
///
/// The reveal (fade into the finished render) is owned by the caller's
/// AnimatedSwitcher — this widget simply gets swapped out, and because every
/// layer here sits behind one 600ms FadeTransition, that swap is the Phase-3
/// cross-fade. No state change in this tree ever hard-cuts.
enum GenerationState { analyzing, rendering }

class GenerationStage extends StatefulWidget {
  const GenerationStage({
    super.key,
    required this.gender,
    required this.category,
    this.backdrop,
    this.onFallback,
  });

  final LoaderGender gender;
  final LoaderCategory category;

  /// The loop for this gender×category is unavailable — the caller should
  /// swap back to its classic loader scene.
  final VoidCallback? onFallback;

  /// The last shown look / the user's photo — blurred stage floor of Phase 1.
  final Uint8List? backdrop;

  @override
  State<GenerationStage> createState() => _GenerationStageState();
}

class _GenerationStageState extends State<GenerationStage>
    with TickerProviderStateMixin {
  GenerationState _state = GenerationState.analyzing;
  bool _videoReady = false;
  bool _videoDead = false;

  late final AnimationController _sweep = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2600))
    ..addStatusListener((st) {
      if (st == AnimationStatus.completed || st == AnimationStatus.dismissed) {
        HapticFeedback.lightImpact();
      }
    })
    ..repeat(reverse: true);

  Timer? _phaseTimer;
  Timer? _progressTimer;
  double _t = 0;

  @override
  void initState() {
    super.initState();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() => _t += 0.1);
    });
    // The veil needs ~2.2s to darken the eyes; switch only once the loop is
    // ALSO decoded — never a black flash, never a buffering frame.
    _phaseTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted) return;
      if (_t >= 2.4 && _videoReady && _state == GenerationState.analyzing) {
        setState(() => _state = GenerationState.rendering);
        _phaseTimer?.cancel();
      }
    });
  }

  @override
  void dispose() {
    _phaseTimer?.cancel();
    _progressTimer?.cancel();
    _sweep.dispose();
    super.dispose();
  }

  /// Monotonic forecast, rendered through a tween so digits tick smoothly.
  double get _percent => (97 * (1 - _exp(-_t / 9))).clamp(0, 97);
  static double _exp(double x) {
    // cheap e^x for the forecast curve (avoids importing dart:math for one call)
    var sum = 1.0, term = 1.0;
    for (var i = 1; i < 12; i++) {
      term *= x / i;
      sum += term;
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final rendering = _state == GenerationState.rendering;
    return IgnorePointer(
      child: Stack(fit: StackFit.expand, children: [
        // ── Scene layer: one 600ms fade between the two stage sets ──
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 600),
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: rendering
              ? const ColoredBox(
                  key: ValueKey('stage-dark'), color: Colors.black)
              : KeyedSubtree(
                  key: const ValueKey('stage-analyzing'),
                  child: _AnalyzingScene(
                      backdrop: widget.backdrop, sweep: _sweep),
                ),
        ),
        // ── Video layer: mounted (and decoding) from frame one, revealed by
        // opacity only — the SAME widget across states, so no re-init. ──
        if (!_videoDead)
          AnimatedOpacity(
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOut,
            opacity: rendering && _videoReady ? 1 : 0,
            child: ColoredBox(
              color: Colors.black,
              child: LooktokVideoLoader(
                gender: widget.gender,
                category: widget.category,
                showFallback: false,
                onReady: () {
                  if (mounted) setState(() => _videoReady = true);
                },
                onUnavailable: () {
                  if (mounted) setState(() => _videoDead = true);
                  widget.onFallback?.call();
                },
              ),
            ),
          ),
        // ── Shared chrome: ONE pill lives across all states (no layout jump),
        // its percent ticking through a tween — 45 → 46 → 47, never leaps. ──
        Positioned(
          left: 16, right: 16, bottom: 56,
          child: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  color: const Color(0xB30A0A0A),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(
                      width: 36,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: _percent),
                        duration: const Duration(milliseconds: 420),
                        curve: Curves.easeOut,
                        builder: (_, v, _) => Text('${v.round()}%',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      child: Text(
                        rendering ? 'Weaving Textures…' : 'Parsing Fit Geometry…',
                        key: ValueKey(rendering),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Phase 1: the blurred photo, an eye-prep veil, a volumetric scanner band.
class _AnalyzingScene extends StatelessWidget {
  const _AnalyzingScene({required this.backdrop, required this.sweep});
  final Uint8List? backdrop;
  final AnimationController sweep;

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      if (backdrop != null)
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
          child: Image.memory(backdrop!,
              fit: BoxFit.cover, gaplessPlayback: true),
        )
      else
        const ColoredBox(color: Color(0xFFF0F0F3)),
      // Eye prep: darken slowly toward the video's black — the later
      // cross-fade lands on already-adapted eyes.
      TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 0.7),
        duration: const Duration(milliseconds: 2200),
        curve: Curves.easeInOut,
        builder: (_, a, _) => ColoredBox(color: Colors.black.withValues(alpha: a)),
      ),
      // Volumetric scanner: a wide soft gradient breathing up and down —
      // no thin lines, no hard edges.
      AnimatedBuilder(
        animation: sweep,
        builder: (_, _) {
          final y = -1.3 + 2.6 * Curves.easeInOut.transform(sweep.value);
          return Align(
            alignment: Alignment(0, y),
            child: FractionallySizedBox(
              widthFactor: 1,
              heightFactor: 0.4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.signature.withValues(alpha: 0),
                      AppColors.signature.withValues(alpha: 0.20),
                      Colors.white.withValues(alpha: 0.24),
                      AppColors.signature.withValues(alpha: 0.20),
                      AppColors.signature.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ]);
  }
}
