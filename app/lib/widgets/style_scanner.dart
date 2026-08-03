import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// "AI Style Scanner" — the render-latency mask, v5.
///
/// Two scenes:
///  · **Atelier** (`overImage: false`) — nothing rendered yet. A soft studio
///    spotlight, an oversized ghost "STYLING" letterform down the left edge,
///    slow counter-rotating dashed orbit rings around the breathing hanger,
///    a fine dot grid — an editorial set piece, not an empty void.
///  · **Overlay** (`overImage: true`) — scanning over the LAST render: just a
///    shimmer wash + the neon line + the garment card, nothing that muddies
///    the photo underneath.
///
/// Shared: NEON scan line (crisp 2px cobalt core, tight glow) with a haptic
/// tick at its bounce points, and ONE frosted forecast pill (monotonic %,
/// plain text swap — no cross-fade garbage).
///
/// Purely theatrical and fault-tolerant: timers/controllers die with the
/// widget; the REAL signal stays the Realtime row — the reveal is never
/// delayed by the animation.
class StyleScanner extends StatefulWidget {
  const StyleScanner(
      {super.key, this.item, this.overImage = false, this.backdrop, this.zone, this.states, this.showTimer = true});

  /// Show the vertical elapsed-timer rail (editor swaps). Generate-look sets
  /// this false — no timer on that loader (owner call).
  final bool showTimer;

  /// The garment being dressed (rail thumb bytes). Null → the hanger alone.
  final Uint8List? item;

  /// True when the scanner sits on top of the last visible render.
  final bool overImage;

  /// The user's uploaded photo — shown HEAVILY blurred behind the atelier
  /// scene (personal, abstract; never a readable raw asset).
  final Uint8List? backdrop;

  /// The slot being dressed ('top' / 'bottom' / 'shoes' / 'accessories') —
  /// the carried garment travels TOWARD that body zone.
  final String? zone;

  /// Override the cycling status lines (flow-relevant copy per caller).
  final List<String>? states;

  @override
  State<StyleScanner> createState() => _StyleScannerState();
}

class _StyleScannerState extends State<StyleScanner>
    with TickerProviderStateMixin {
  static const _defaultStates = [
    'Parsing Fit Geometry…',
    'Analyzing Tone Compliance…',
    'Weaving Textures…',
  ];
  List<String> get _states => widget.states ?? _defaultStates;

  late final AnimationController _hanger = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat(reverse: true);
  late final AnimationController _sweep = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2400))
    ..addStatusListener(_onBounce)
    ..repeat(reverse: true);
  late final AnimationController _orbit = AnimationController(
      vsync: this, duration: const Duration(seconds: 14))
    ..repeat();
  late final AnimationController _pop = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 700))
    ..forward();
  Timer? _stateTimer;
  Timer? _progressTimer;
  int _state = 0;
  double _t = 0; // seconds elapsed — drives the asymptotic forecast

  void _onBounce(AnimationStatus st) {
    // Tactile pulse exactly at the line's turn-around points.
    if (st == AnimationStatus.completed || st == AnimationStatus.dismissed) {
      HapticFeedback.lightImpact();
    }
  }

  @override
  void initState() {
    super.initState();
    _stateTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      if (!mounted) return;
      setState(() => _state = (_state + 1) % _states.length);
    });
    _progressTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      setState(() => _t += 0.1);
    });
  }

  @override
  void dispose() {
    _stateTimer?.cancel();
    _progressTimer?.cancel();
    _hanger.dispose();
    _sweep.dispose();
    _orbit.dispose();
    _pop.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(fit: StackFit.expand, children: [
        if (widget.overImage)
          // Over a render: an 11% white wash keeps the photo clearly visible.
          Container(color: const Color(0x1CFFFFFF))
        else ...[
          // ── ATELIER SET ────────────────────────────────────────────────
          // BASE (always, full-bleed): studio gradient fills the WHOLE frame to
          // the very bottom edge, so there is NEVER a white scaffold gap under
          // the blurred photo — the backdrop reads as reaching the screen floor.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFF4F3F0), Color(0xFFECEAE4), Color(0xFFD8D5CB), Color(0xFFC7C3B8)],
                  stops: [0.0, 0.45, 0.82, 1.0],
                ),
              ),
            ),
          ),
          // The user's own photo, blurred into an abstract wash on TOP of the
          // base. Scaled up so the heavy blur's soft edges bleed OFF-screen
          // (otherwise the blur samples past the bounds and looks "cut").
          if (widget.backdrop != null)
            Positioned.fill(
              child: Transform.scale(
                scale: 1.3,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                  child: Image.memory(widget.backdrop!,
                      fit: BoxFit.cover, gaplessPlayback: true),
                ),
              ),
            ),
          // Milk veil: a light editorial wash for readability — kept LIGHT so
          // the backdrop stays visible all the way down (was fading to white).
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x66FFFFFF), Color(0x80FFFFFF), Color(0x8CFFFFFF)],
              ),
            ),
          ),
          // Studio FLOOR: a grounded taupe wash on the bottom so the backdrop
          // clearly reaches the screen's bottom edge — the white-bg cutout
          // blurs to near-white below the feet, which read as empty otherwise.
          const Positioned(
            left: 0, right: 0, bottom: 0,
            height: 320,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00C7C3B8), Color(0x4DBAB6AA), Color(0x99A8A497)],
                ),
              ),
            ),
          ),
          // Fine dot grid — editorial paper texture (skipped over a photo).
          if (widget.backdrop == null) CustomPaint(painter: _DotGridPainter()),
          // Ghost letterform down the left edge — the brand's oversized type.
          Positioned(
            left: -8, top: 0, bottom: 0,
            child: RotatedBox(
              quarterTurns: 3,
              child: Center(
                child: Text(
                  'STYLING',
                  style: TextStyle(
                    fontSize: 96,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -2,
                    height: 1,
                    decoration: TextDecoration.none,
                    foreground: Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = 2.2
                      ..color = AppColors.ink.withValues(alpha: 0.34),
                  ),
                ),
              ),
            ),
          ),
          // Orbit rings around the hanger — the atelier turntable.
          Center(
            child: AnimatedBuilder(
              animation: _orbit,
              builder: (_, _) => Transform.rotate(
                angle: _orbit.value * 2 * math.pi,
                child: CustomPaint(
                    size: const Size(190, 190),
                    painter: _OrbitPainter(radiusFrac: 1.0, dashes: 44, alpha: 0.32)),
              ),
            ),
          ),
          Center(
            child: AnimatedBuilder(
              animation: _orbit,
              builder: (_, _) => Transform.rotate(
                angle: -_orbit.value * 2 * math.pi * 0.6,
                child: CustomPaint(
                    size: const Size(138, 138),
                    painter: _OrbitPainter(radiusFrac: 1.0, dashes: 32, alpha: 0.5)),
              ),
            ),
          ),
          // Cobalt halo under the hanger.
          Center(
            child: Container(
              width: 120, height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  AppColors.signature.withValues(alpha: 0.22),
                  AppColors.signature.withValues(alpha: 0),
                ]),
              ),
            ),
          ),
        ],
        // NEON scan line: tight glow + crisp core, gliding up and down.
        AnimatedBuilder(
          animation: _sweep,
          builder: (_, _) {
            final y = -1.0 + 2.0 * Curves.easeInOut.transform(_sweep.value);
            return Align(
              alignment: Alignment(0, y),
              child: SizedBox(
                height: 18,
                width: double.infinity,
                child: Stack(alignment: Alignment.center, children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          AppColors.signature.withValues(alpha: 0),
                          AppColors.signature.withValues(alpha: 0.22),
                          AppColors.signature.withValues(alpha: 0),
                        ],
                      ),
                    ),
                    child: const SizedBox.expand(),
                  ),
                  Container(
                    height: 2,
                    decoration: BoxDecoration(
                      color: AppColors.signature,
                      boxShadow: [
                        BoxShadow(
                            color: AppColors.signature.withValues(alpha: 0.55),
                            blurRadius: 8,
                            spreadRadius: 0.5),
                      ],
                    ),
                  ),
                ]),
              ),
            );
          },
        ),
        // The dressing choreography: the garment hangs on a rail hook and is
        // CARRIED IN from the right edge, then rhythmically brought up to the
        // avatar — lean in, press, ease back — like a fitting at the mirror.
        // (No item → the classic bobbing hanger.)
        Align(
          alignment: widget.item == null
              ? Alignment.center
              : switch ((widget.zone ?? 'top').toLowerCase()) {
                  // Beside the zone it's dressing: chest / hips / feet.
                  'bottom' || 'bottoms' => const Alignment(0.68, 0.22),
                  'shoes' || 'footwear' => const Alignment(0.68, 0.72),
                  'glasses' => const Alignment(0.68, -0.62), // eye line
                  'jewelry' => const Alignment(0.68, -0.44), // neckline
                  'watch' => const Alignment(0.68, 0.08), // wrist height
                  'accessories' => const Alignment(0.68, -0.28),
                  _ => const Alignment(0.68, -0.34), // top → chest level
                },
          child: AnimatedBuilder(
            animation: Listenable.merge([_hanger, _sweep, _pop]),
            builder: (_, _) {
              final t = Curves.easeInOut.transform(_hanger.value);
              if (widget.item == null) {
                return Transform.translate(
                  offset: Offset(0, -7 * t),
                  child: Transform.rotate(
                    angle: (t - 0.5) * 0.28,
                    child: const Icon(Icons.checkroom,
                        size: 46, color: AppColors.signature),
                  ),
                );
              }
              // Entry: carried in from offscreen right, settling with ease.
              final entry = Curves.easeOutCubic.transform(_pop.value);
              final dxEntry = 240 * (1 - entry);
              // Fitting rhythm: press toward the avatar at mid-sweep, ease
              // back at the ends (where the haptic ticks land).
              final sweepT = Curves.easeInOut.transform(_sweep.value);
              final press = math.sin(sweepT * math.pi);
              final dxPress = -44 * press;
              final lean = -0.12 * press; // leans IN toward the body
              final glow = press;
              return Opacity(
                opacity: entry.clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(dxEntry + dxPress, -4 * t),
                  child: Transform.rotate(
                    angle: lean + (sweepT - 0.5) * 0.05,
                    alignment: Alignment.topCenter,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      // The rail hook the piece travels on.
                      Icon(Icons.checkroom,
                          size: 30,
                          color: AppColors.ink.withValues(alpha: 0.75)),
                      Container(
                        width: 1.6, height: 10,
                        color: AppColors.ink.withValues(alpha: 0.35),
                      ),
                      SizedBox(
                        width: 96, height: 116,
                        child: Stack(clipBehavior: Clip.none, children: [
                          Container(
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                  color: Color.lerp(AppColors.line,
                                      AppColors.signature, glow * 0.7)!),
                              boxShadow: [
                                const BoxShadow(
                                    color: Color(0x24000000),
                                    blurRadius: 18,
                                    offset: Offset(0, 10)),
                                BoxShadow(
                                    color: AppColors.signature
                                        .withValues(alpha: 0.38 * glow),
                                    blurRadius: 24,
                                    spreadRadius: 1),
                              ],
                            ),
                            child: Stack(fit: StackFit.expand, children: [
                              Padding(
                                padding: const EdgeInsets.all(6),
                                child: Image.memory(widget.item!,
                                    fit: BoxFit.contain,
                                    gaplessPlayback: true),
                              ),
                              // Gloss sweeping the fabric with each press.
                              IgnorePointer(
                                child: Transform.translate(
                                  offset: Offset(-130 + 260 * sweepT, 0),
                                  child: Transform.rotate(
                                    angle: 0.5,
                                    child: Container(
                                      width: 36,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.centerLeft,
                                          end: Alignment.centerRight,
                                          colors: [
                                            Colors.white.withValues(alpha: 0),
                                            Colors.white.withValues(alpha: 0.5),
                                            Colors.white.withValues(alpha: 0),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ]),
                          ),
                        ]),
                      ),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
        // Progress CHIP — compact, LEFT edge, vertically centered (owner call:
        // out of the way of the Wear FAB + carried garment on the right/bottom).
        // Three pulsing cobalt dots + an honest elapsed timer; a calm "almost
        // there" once past ~25s.
        // VERTICAL timer rail on the left edge — a tall column that fills as
        // time elapses (tangible progress) with the elapsed clock on top.
        // More visible & ergonomic than a small horizontal pill (owner call).
        if (widget.showTimer)
        Positioned(
          left: 16, top: 0, bottom: 0,
          child: Center(
            child: Builder(builder: (_) {
              const railH = 200.0;
              final frac = (_t / 25).clamp(0.04, 0.98);
              final secs = _t.floor();
              final clock = '0:${secs.remainder(60).toString().padLeft(2, '0')}';
              return Column(mainAxisSize: MainAxisSize.min, children: [
                Text(clock,
                    style: const TextStyle(
                        color: AppColors.ink, fontSize: 13,
                        fontWeight: FontWeight.w800, decoration: TextDecoration.none,
                        fontFeatures: [FontFeature.tabularFigures()])),
                const SizedBox(height: 10),
                Container(
                  width: 10, height: railH,
                  decoration: BoxDecoration(
                    color: const Color(0xE6FFFFFF),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0xFFE6E3DC)),
                    boxShadow: const [
                      BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, 2)),
                    ],
                  ),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 10, height: railH * frac.toDouble(),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        gradient: const LinearGradient(
                          begin: Alignment.topCenter, end: Alignment.bottomCenter,
                          colors: [Color(0xFF6E8BFF), AppColors.signature],
                        ),
                        boxShadow: [
                          BoxShadow(
                              color: AppColors.signature.withValues(alpha: 0.5),
                              blurRadius: 8, spreadRadius: 0.5),
                        ],
                      ),
                    ),
                  ),
                ),
              ]);
            }),
          ),
        ),
      ]),
    );
  }
}

/// Fine dot grid — quiet editorial texture for the atelier scene.
class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = AppColors.ink.withValues(alpha: 0.05);
    const pitch = 26.0;
    for (var x = pitch / 2; x < size.width; x += pitch) {
      for (var y = pitch / 2; y < size.height; y += pitch) {
        canvas.drawCircle(Offset(x, y), 1.0, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGridPainter oldDelegate) => false;
}

/// Dashed orbit ring (the atelier turntable) — rotated by the caller.
class _OrbitPainter extends CustomPainter {
  const _OrbitPainter(
      {required this.radiusFrac, required this.dashes, required this.alpha});
  final double radiusFrac;
  final int dashes;
  final double alpha;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2 * radiusFrac - 1;
    final c = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..color = AppColors.ink.withValues(alpha: alpha);
    final gap = 2 * math.pi / dashes;
    for (var i = 0; i < dashes; i++) {
      final start = i * gap;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), start, gap * 0.45,
          false, paint);
    }
  }

  @override
  bool shouldRepaint(_OrbitPainter oldDelegate) => false;
}
