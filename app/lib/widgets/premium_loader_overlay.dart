import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Dark-studio backdrop for transparent-PNG silhouettes: a subtle radial pool
/// of light (#2A2A2A) fading to black at the edges — never a plain white slab.
/// The center sits slightly above middle so the figure reads "lit from above".
class StudioBackdrop extends StatelessWidget {
  const StudioBackdrop({super.key, this.child});
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.25),
          radius: 1.1,
          colors: [Color(0xFF2A2A2A), Color(0xFF161618), Color(0xFF000000)],
          stops: [0.0, 0.55, 1.0],
        ),
      ),
      child: child ?? const SizedBox.expand(),
    );
  }
}

/// Global "AI is working" overlay, shared by every processing pipeline.
///
/// Truly full-screen: the blurred context image and dark scene cover the
/// ENTIRE canvas (host screens draw it edge-to-edge), while the checklist
/// itself sits in a SafeArea so text never collides with the notch or home
/// indicator. The checklist is STAGGERED: items fade-slide in one after
/// another, the active step carries a pulsing ring, completed steps collapse
/// to a solid white check with dimmed text.
class PremiumLoaderOverlay extends StatefulWidget {
  const PremiumLoaderOverlay({
    super.key,
    required this.stages,
    this.image,
    this.stageDuration = const Duration(milliseconds: 1500),
  });

  /// Status lines, shown as a lighting-up checklist.
  final List<String> stages;

  /// Optional context image (e.g. the look being judged) — blurred + veiled.
  /// Null → pure studio gradient.
  final Uint8List? image;

  final Duration stageDuration;

  @override
  State<PremiumLoaderOverlay> createState() => _PremiumLoaderOverlayState();
}

class _PremiumLoaderOverlayState extends State<PremiumLoaderOverlay> {
  int _stage = 0; // which step is ACTIVE (earlier ones are done)
  int _appeared = 0; // staggered entry: how many rows are visible yet
  Timer? _stageTimer;
  Timer? _entryTimer;

  @override
  void initState() {
    super.initState();
    // Entry choreography: one row every 330ms — they do NOT appear at once.
    _entryTimer = Timer.periodic(const Duration(milliseconds: 330), (t) {
      if (!mounted) return;
      setState(() => _appeared++);
      if (_appeared >= widget.stages.length) t.cancel();
    });
    // Progress choreography: the active step advances on its own cadence and
    // holds on the last one until the caller swaps the UI.
    _stageTimer = Timer.periodic(widget.stageDuration, (_) {
      if (!mounted) return;
      setState(() => _stage = (_stage + 1).clamp(0, widget.stages.length - 1));
    });
  }

  @override
  void dispose() {
    _stageTimer?.cancel();
    _entryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      // Scene layers ignore ALL insets — the dark canvas owns the full screen.
      const StudioBackdrop(),

      // The checklist respects the device: no notch/home-indicator collisions.
      SafeArea(
        child: Center(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The photo as an OBJECT, not wallpaper: a sharp framed card
                // on the dark studio table, scanned by the cobalt line inside
                // its own frame.
                if (widget.image != null) ...[
                  Center(
                    child: Container(
                      width: 168, height: 224,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B1B1D),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0x2EFFFFFF)),
                        boxShadow: const [
                          BoxShadow(
                              color: Color(0x66000000),
                              blurRadius: 30,
                              offset: Offset(0, 14)),
                        ],
                      ),
                      child: Stack(fit: StackFit.expand, children: [
                        Image.memory(widget.image!,
                            fit: BoxFit.cover, gaplessPlayback: true),
                        const _SweepLine(),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 26),
                ],
                for (var i = 0; i < widget.stages.length; i++)
                  AnimatedSlide(
                    offset: i < _appeared ? Offset.zero : const Offset(0, 0.35),
                    duration: const Duration(milliseconds: 380),
                    curve: Curves.easeOutCubic,
                    child: AnimatedOpacity(
                      opacity: i < _appeared ? 1 : 0,
                      duration: const Duration(milliseconds: 380),
                      child: _StageRow(
                        label: widget.stages[i],
                        done: i < _stage,
                        active: i == _stage,
                      ),
                    ),
                  ),
              ]),
        ),
      ),
    ]);
  }
}

/// Cobalt scan line gliding over the scene — the brand's scanner language,
/// shared with the editor's StyleScanner. Motion = alive, not печальный.
class _SweepLine extends StatefulWidget {
  const _SweepLine();
  @override
  State<_SweepLine> createState() => _SweepLineState();
}

class _SweepLineState extends State<_SweepLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2800))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) {
          final y = -1.0 + 2.0 * Curves.easeInOut.transform(_c.value);
          return Align(
            alignment: Alignment(0, y),
            child: SizedBox(
              height: 64,
              width: double.infinity,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0x002E5BFF),
                      const Color(0x1F2E5BFF),
                      const Color(0x8C2E5BFF),
                      const Color(0x002E5BFF),
                    ],
                    stops: const [0, 0.6, 0.985, 1],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow({required this.label, required this.done, required this.active});
  final String label;
  final bool done;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 26, height: 26,
          child: done
              // Completed: solid white disc + black check.
              ? Container(
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                  child: const Icon(Icons.check, size: 15, color: Colors.black),
                )
              : active
                  ? const _PulsingRing()
                  // Pending: quiet outline.
                  : Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24, width: 1.5),
                      ),
                    ),
        ),
        const SizedBox(width: 14),
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 300),
          style: TextStyle(
            // Done steps dim slightly; the active one carries the weight.
            color: active ? Colors.white : (done ? Colors.white60 : Colors.white38),
            fontSize: 15,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            letterSpacing: -0.2,
            decoration: TextDecoration.none,
          ),
          child: Text(label),
        ),
      ]),
    );
  }
}

/// The active step's indicator: a spinning ring inside a soft breathing halo.
class _PulsingRing extends StatefulWidget {
  const _PulsingRing();
  @override
  State<_PulsingRing> createState() => _PulsingRingState();
}

class _PulsingRingState extends State<_PulsingRing> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) {
        final t = Curves.easeInOut.transform(_c.value);
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.5),
            boxShadow: [
              BoxShadow(
                  color: Colors.white.withValues(alpha: 0.10 + 0.22 * t),
                  blurRadius: 8 + 8 * t),
            ],
          ),
          child: child,
        );
      },
      child: const Padding(
        padding: EdgeInsets.all(5),
        child: CircularProgressIndicator(strokeWidth: 1.6, color: Colors.white),
      ),
    );
  }
}
