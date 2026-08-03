import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../paywall_gate.dart';
import '../providers.dart';
import '../services/api_client.dart' show PaywallRequired, IdentityMismatchException;
import '../services/native_looktok_engine.dart';
import '../flags.dart';
import '../theme.dart';
import 'look_editor_screen.dart';
import '../services/photo_validator.dart';
import '../widgets/shimmer.dart';

/// Fitting Room Copilot — the O2O flagship. In a store, trying several outfits:
/// snap 2–4 mirror selfies, the AI ranks them for YOUR build and explains why.
/// Winner card with TOP PICK badge, swipeable runners-up with polite critique,
/// and a Smart Commerce module when nothing scores well.
class CompareLooksScreen extends ConsumerStatefulWidget {
  const CompareLooksScreen({super.key});
  @override
  ConsumerState<CompareLooksScreen> createState() => _CompareLooksScreenState();
}

class _CompareLooksScreenState extends ConsumerState<CompareLooksScreen> {
  final List<Uint8List?> _slots = List.filled(4, null);
  // null = the entry question ("what are we comparing?"); 'looks' = outfit
  // showdown; 'piece' = which VARIANT of one garment suits me.
  String? _mode;
  Future<List<Map<String, dynamic>>>? _verdict;
  List<Uint8List> _judged = const []; // the photos sent, by original index

  List<Uint8List> get _photos => [for (final b in _slots) ?b];

  // NOTE: the picker no longer auto-opens — with TWO judgement modes (best
  // look / best piece) the user picks the job first, then the photos. The
  // multi-pick button still starts the showdown the moment 2+ photos land.

  /// Select 2-4 looks in ONE picker session (no per-tile uploads).
  Future<void> _pickMulti({bool autoStart = false}) async {
    final files = await ImagePicker().pickMultiImage(
        maxWidth: 1600, maxHeight: 1600, imageQuality: 85, limit: 4);
    if (files.isEmpty || !mounted) return;
    var slot = _photos.length;
    var skipped = 0;
    for (final f in files.take(4 - slot)) {
      final bytes = await f.readAsBytes();
      if (!mounted) return;
      // Same gate as single picks: blurry/empty shots sink the whole verdict.
      if (!await PhotoValidator.instance
          .validateAndProceed(context, bytes, ValidationFlowType.fullBody)) {
        skipped++;
        continue;
      }
      if (!mounted) return;
      setState(() => _slots[slot++] = bytes);
    }
    if (!mounted) return;
    if (skipped > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$skipped photo${skipped == 1 ? '' : 's'} skipped — retake them full-length in the mirror.')));
    }
    if (autoStart && _photos.length >= 2) await _compare();
  }

  Future<void> _pick(int i) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppColors.bg,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined, color: AppColors.ink),
            title: const Text('Take a photo', style: TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined, color: AppColors.ink),
            title: const Text('Choose from gallery', style: TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (source == null) return;
    // Hot path: native zero-lag capture; Flutter picker = fallback + gallery.
    Uint8List? bytes;
    if (source == ImageSource.camera) {
      bytes = await NativeLooktokEngine.instance.captureHighResPhoto();
    }
    if (bytes == null) {
      // 1600px (not the usual 800): these cutouts are displayed FULL SCREEN on
      // the verdict cards — an 800px source upscaled 3× reads blurry. Matches
      // the native capture spec; payload stays sane (cleaned PNGs go to Gemini).
      final f = await ImagePicker().pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 85);
      if (f == null) return;
      bytes = await f.readAsBytes();
    }
    if (!mounted) return;
    // Centralized interceptor: a blurry or empty mirror shot would sink the
    // whole comparison — the retake sheet bounces it now.
    if (!await PhotoValidator.instance
        .validateAndProceed(context, bytes, ValidationFlowType.fullBody)) {
      return;
    }
    if (!mounted) return;
    setState(() => _slots[i] = bytes);
  }

  Future<void> _compare() async {
    if (!await ensureTokens(context, ref)) return;
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    final photos = _photos;
    final pipeline = ref.read(smartImageProcessingProvider);
    setState(() {
      _judged = photos;
      // Unified pipeline: isolate silhouettes → Gemini ranks them. onCleaned
      // swaps the loader/cards to the clean cutouts the moment they're ready.
      _verdict = () async {
        try {
          final r = await pipeline.processAndCompare(photos, mode: _mode ?? 'looks',
              onCleaned: (cleaned) {
            if (mounted) setState(() => _judged = cleaned);
          });
          ref.invalidate(entitlementProvider); // a credit was burned
          return r.looks;
        } on IdentityMismatchException catch (e) {
          // The engine says some selfies are NOT the account owner — alert
          // loudly (the ranking is calibrated to YOUR build; judging someone
          // else silently would be garbage advice). No credit was burned.
          if (mounted) {
            showDialog<void>(
              context: context,
              builder: (d) => AlertDialog(
                icon: const Icon(Icons.person_off_outlined, size: 30),
                title: const Text('These don’t look like your photos'),
                content: Text(
                    'Compare is tuned to YOUR body profile, and '
                    '${e.mismatchedIndexes.length} of the photos show someone '
                    'else. Retake them with yourself in the mirror — no credit '
                    'was used.'),
                actions: [
                  FilledButton(
                      onPressed: () => Navigator.pop(d), child: const Text('Got it')),
                ],
              ),
            );
          }
          rethrow; // the error state below shows the same reason
        }
      }();
    });
  }

  void _reset() => setState(() {
        _verdict = null;
        _judged = const [];
        for (var i = 0; i < _slots.length; i++) {
          _slots[i] = null;
        }
      });

  @override
  Widget build(BuildContext context) {
    // Verdict/loader mode is a FULL-DARK experience: black scaffold drawn
    // edge-to-edge (extendBody* — no white bars at notch or home indicator),
    // light status-bar icons. Content manages its own safe insets.
    final dark = _verdict != null;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
      backgroundColor: dark ? Colors.black : Colors.white,
      extendBody: true,
      extendBodyBehindAppBar: false, // the AppBar stays a solid element
      appBar: AppBar(
        backgroundColor: dark ? Colors.black : Colors.white,
        foregroundColor: dark ? Colors.white : AppColors.ink,
        title: Text('compare.title'.tr()),
      ),
      body: !dark
          ? SafeArea(child: _mode == null ? _chooser() : _input())
          : FutureBuilder<List<Map<String, dynamic>>>(
                future: _verdict,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    // The SHOWDOWN scanner: fanned deck of the contenders under
                    // a neon judge line — no checklist rows (owner ban).
                    return _CompareScanner(
                      photos: _judged,
                      stages: ['compare.stage1'.tr(), 'compare.stage2'.tr(), 'compare.stage3'.tr()],
                    );
                  }
                  if (snap.hasError || (snap.data?.isEmpty ?? true)) {
                    final quota = snap.error is PaywallRequired;
                    final identity = snap.error is IdentityMismatchException;
                    return Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(
                            identity
                                ? 'These don’t look like your photos'
                                : quota
                                    ? 'No reads left'
                                    : 'Couldn’t judge this set',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 14),
                        FilledButton(onPressed: _reset, child: Text('compare.tryAgain'.tr())),
                      ]),
                    );
                  }
                  return _Showdown(looks: snap.data!, photos: _judged, onReset: _reset);
                },
              ),
      ),
    );
  }

  /// Entry question: what are we comparing? Two large cards, one decision.
  Widget _chooser() {
    Widget option({
      required String title,
      required String caption,
      required String detail,
      required IconData icon,
      required VoidCallback onTap,
    }) {
      return GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.line),
            boxShadow: const [
              BoxShadow(color: Color(0x0A000000), blurRadius: 24, offset: Offset(0, 8)),
            ],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 46, height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFF2F0EB),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, size: 22, color: AppColors.ink),
            ),
            const SizedBox(height: 14),
            Text(title,
                style: const TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
            const SizedBox(height: 4),
            Text(caption,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.inkSoft)),
            const SizedBox(height: 6),
            Text(detail, style: const TextStyle(fontSize: 12.5, color: AppColors.muted, height: 1.35)),
          ]),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('What are we\ncomparing?',
            style: TextStyle(fontSize: 34, height: 1.05, fontWeight: FontWeight.w800, letterSpacing: -1.2)),
        const SizedBox(height: 22),
        option(
          title: 'Looks',
          caption: 'Which outfit wins?',
          detail: 'Snap 2–4 full outfits — I\'ll rank them for your build and say why.',
          icon: Icons.style_outlined,
          onTap: () => setState(() => _mode = 'looks'),
        ),
        const SizedBox(height: 14),
        option(
          title: 'One piece',
          caption: 'Which one suits me?',
          detail: 'Trying variants of the same thing — three blouses, two jackets? I\'ll pick the one that flatters you.',
          icon: Icons.checkroom_outlined,
          onTap: () => setState(() => _mode = 'piece'),
        ),
      ]),
    );
  }

  // ── Input: premium 2×2 grid + activating CTA ───────────────────────────────
  Widget _input() {
    final count = _photos.length;
    final canCompare = count >= 2;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Mode-specific shooting hint — HOW to photograph so the verdict
          // is actually judging the right thing.
          Builder(builder: (_) {
            final piece = _mode == 'piece';
            final steps = piece
                ? const [
                    ('1', 'Keep the rest of the outfit exactly the same.'),
                    ('2', 'Swap ONLY the piece you\'re choosing — one full-length shot per variant.'),
                  ]
                : const [
                    ('1', 'Wear each outfit, snap a full-length mirror selfie.'),
                    ('2', 'Same spot, same light — 2–4 shots, one per outfit.'),
                  ];
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              decoration: BoxDecoration(
                color: const Color(0xFFF2F0EB),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(piece ? 'Change only the piece.' : 'One photo per outfit.',
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
                  const SizedBox(height: 8),
                  for (final (n, t) in steps)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(
                          width: 18, height: 18,
                          alignment: Alignment.center,
                          margin: const EdgeInsets.only(top: 1),
                          decoration: const BoxDecoration(
                              color: AppColors.ink, shape: BoxShape.circle),
                          child: Text(n,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(t,
                              style: const TextStyle(
                                  fontSize: 12.5, height: 1.35, color: AppColors.inkSoft)),
                        ),
                      ]),
                    ),
                ],
              ),
            );
          }),
          const SizedBox(height: 14),
          // Two distinct jobs, one screen — pick the judgement you need.
          Row(children: [
            Expanded(
              child: _ModeCard(
                on: _mode == 'looks',
                title: 'Best look',
                caption: 'Which outfit wins?',
                icon: Icons.style_outlined,
                onTap: () => setState(() => _mode = 'looks'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ModeCard(
                on: _mode == 'piece',
                title: 'Best piece',
                caption: 'Which one suits me?',
                icon: Icons.checkroom_outlined,
                onTap: () => setState(() => _mode = 'piece'),
              ),
            ),
          ]),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _photos.length >= 4 ? null : () => _pickMulti(autoStart: false),
              icon: const Icon(Icons.photo_library_outlined, size: 18),
              label: const Text('Select 2–4 from gallery',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.ink,
                side: const BorderSide(color: AppColors.ink, width: 1.4),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2, mainAxisSpacing: 14, crossAxisSpacing: 14, childAspectRatio: 3 / 4),
              itemCount: 4,
              itemBuilder: (_, i) {
                final b = _slots[i];
                if (b == null) {
                  final isNext = i == count;
                  return GestureDetector(
                    onTap: () => _pick(i),
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(AppRadius.card),
                        border: Border.all(
                          color: isNext ? AppColors.signature : AppColors.line,
                          width: isNext ? 1.5 : 1,
                        ),
                      ),
                      child: Stack(alignment: Alignment.center, children: [
                        // B&W hint: a faint full-length figure watermark — reads
                        // "your mirror selfie goes here" without hiding the
                        // tap-to-add affordance in front of it.
                        Positioned.fill(
                          child: FittedBox(
                            fit: BoxFit.cover,
                            alignment: Alignment.bottomCenter,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 30),
                              child: Icon(Icons.accessibility_new_rounded,
                                  color: AppColors.ink.withValues(alpha: 0.05)),
                            ),
                          ),
                        ),
                        Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Container(
                            width: 46, height: 46,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: isNext ? AppColors.signature : AppColors.line),
                              boxShadow: const [
                                BoxShadow(color: Color(0x11000000), blurRadius: 8, offset: Offset(0, 2)),
                              ],
                            ),
                            child: Icon(Icons.add_a_photo_outlined,
                                size: 21, color: isNext ? AppColors.signature : AppColors.muted),
                          ),
                          const SizedBox(height: 9),
                          Text('compare.addPhoto'.tr(),
                              style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: isNext ? AppColors.ink : AppColors.muted)),
                          const SizedBox(height: 2),
                          Text('full-length',
                              style: TextStyle(
                                  fontSize: 9.5, letterSpacing: 0.8,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.muted.withValues(alpha: 0.7))),
                        ]),
                      ]),
                    ),
                  );
                }
                return Stack(fit: StackFit.expand, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    child: Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true),
                  ),
                  Positioned(
                    top: 6, right: 6,
                    child: GestureDetector(
                      onTap: () => setState(() => _slots[i] = null),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(color: Color(0xCC0A0A0A), shape: BoxShape.circle),
                        child: const Icon(Icons.close, size: 15, color: Colors.white),
                      ),
                    ),
                  ),
                ]);
              },
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: canCompare ? _compare : null,
              icon: const Icon(Icons.auto_awesome, size: 18, color: AppColors.signature),
              label: Text('${'compare.button'.tr()}${count >= 2 ? ' ($count)' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}

/// The verdict: swipeable ranked cards. Page 0 = winner with the TOP PICK badge
/// and the "why" container; runners-up carry their polite critique.
/// Dark "fitting-room showdown" loader: the contender photos fan out like a
/// hand of cards over a blurred backdrop, a neon judge-line sweeps them, ONE
/// frosted pill narrates progress. Purely theatrical — the verdict future is
/// the only real signal.
class _CompareScanner extends StatefulWidget {
  const _CompareScanner({required this.photos, required this.stages});
  final List<Uint8List> photos;
  final List<String> stages;
  @override
  State<_CompareScanner> createState() => _CompareScannerState();
}

class _CompareScannerState extends State<_CompareScanner>
    with TickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2600))
    ..addStatusListener((st) {
      if (st == AnimationStatus.completed || st == AnimationStatus.dismissed) {
        HapticFeedback.lightImpact();
      }
    })
    ..repeat(reverse: true);
  late final AnimationController _pop = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 800))
    ..forward();
  Timer? _stateTimer;
  Timer? _progressTimer;
  int _state = 0;
  double _t = 0;

  @override
  void initState() {
    super.initState();
    _stateTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (mounted) setState(() => _state = (_state + 1) % widget.stages.length);
    });
    _progressTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() => _t += 0.1);
    });
  }

  @override
  void dispose() {
    _stateTimer?.cancel();
    _progressTimer?.cancel();
    _sweep.dispose();
    _pop.dispose();
    super.dispose();
  }

  int get _percent => (97 * (1 - math.exp(-_t / 8))).round().clamp(0, 97);

  @override
  Widget build(BuildContext context) {
    final n = widget.photos.length;
    return Stack(fit: StackFit.expand, children: [
      // Light editorial studio — soft ivory radial + floor, not a dark stage.
      const Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.25), radius: 1.3,
              colors: [Color(0xFFF9F8F5), Color(0xFFF1F0EB), Color(0xFFE7E5DE)],
              stops: [0.0, 0.55, 1.0],
            ),
          ),
        ),
      ),
      // Ghost brand word — oversized ink type, faint (editorial register).
      Positioned(
        left: -6, top: 0, bottom: 0,
        child: RotatedBox(
          quarterTurns: 3,
          child: Center(
            child: Text('STYLING',
                style: TextStyle(
                  fontSize: 96, fontWeight: FontWeight.w900,
                  letterSpacing: -2, height: 1, decoration: TextDecoration.none,
                  color: AppColors.ink.withValues(alpha: 0.045),
                )),
          ),
        ),
      ),
      // Contenders — clean cards on light, the one under review lifts + rims
      // cobalt, the rest hold back. Soft dark shadow on light (not floating).
      Center(
        child: AnimatedBuilder(
          animation: Listenable.merge([_sweep, _pop]),
          builder: (context, _) {
            final entry = Curves.easeOutCubic.transform(_pop.value);
            final focus = n == 0 ? 0 : (_t / 2.2).floor() % n;
            final size = MediaQuery.of(context).size;
            final cardW = (size.width - 24 * 2 - 14) / 2;
            return Opacity(
              opacity: entry.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, 24 * (1 - entry)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 14, runSpacing: 14,
                    children: [
                      for (var i = 0; i < n; i++)
                        Builder(builder: (_) {
                          final on = i == focus;
                          return AnimatedScale(
                            duration: const Duration(milliseconds: 420),
                            curve: Curves.easeOutCubic,
                            scale: on ? 1.04 : 0.97,
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 420),
                              opacity: on ? 1 : 0.7,
                              child: Transform.rotate(
                                angle: (i.isEven ? -1 : 1) * 0.012,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 420),
                                  width: cardW,
                                  height: cardW * 4.2 / 3,
                                  clipBehavior: Clip.antiAlias,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                        width: on ? 1.8 : 1,
                                        color: on
                                            ? AppColors.signature
                                            : const Color(0xFFE6E3DC)),
                                    boxShadow: [
                                      BoxShadow(
                                          color: Color(on ? 0x1A000000 : 0x12000000),
                                          blurRadius: on ? 26 : 16,
                                          offset: const Offset(0, 12)),
                                      if (on)
                                        BoxShadow(
                                            color: AppColors.signature
                                                .withValues(alpha: 0.22),
                                            blurRadius: 26, spreadRadius: 1),
                                    ],
                                  ),
                                  child: Image.memory(widget.photos[i],
                                      fit: BoxFit.cover, gaplessPlayback: true),
                                ),
                              ),
                            ),
                          );
                        }),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
      // Soft cobalt scan sweep (subtle on light).
      AnimatedBuilder(
        animation: _sweep,
        builder: (_, _) {
          final y = -0.72 + 1.44 * Curves.easeInOut.transform(_sweep.value);
          return Align(
            alignment: Alignment(0, y),
            child: FractionallySizedBox(
              widthFactor: 1, heightFactor: 0.12,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [
                      AppColors.signature.withValues(alpha: 0),
                      AppColors.signature.withValues(alpha: 0.14),
                      AppColors.signature.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
      // Progress pill — ink on light, matches the rest of the app's loaders.
      Positioned(
        left: 16, right: 16, bottom: 56,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.ink,
              borderRadius: BorderRadius.circular(999),
              boxShadow: const [
                BoxShadow(color: Color(0x22000000), blurRadius: 16, offset: Offset(0, 6)),
              ],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: 34,
                child: Text('$_percent%',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 6),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: Text(widget.stages[_state],
                    key: ValueKey(_state),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }
}

class _Showdown extends ConsumerStatefulWidget {
  const _Showdown({required this.looks, required this.photos, required this.onReset});
  final List<Map<String, dynamic>> looks; // sorted best-first by the backend
  final List<Uint8List> photos; // by original index
  final VoidCallback onReset;
  @override
  ConsumerState<_Showdown> createState() => _ShowdownState();
}

class _ShowdownState extends ConsumerState<_Showdown> {
  final _pager = PageController(viewportFraction: 0.92);
  int _page = 0;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  bool get _allWeak => widget.looks.every((l) => ((l['score'] as num?) ?? 0) < 55);

  /// Take the current look into the editor: fix the exact weaknesses the
  /// verdict named, swap pieces, shop from there — the product's core loop.
  void _improve() {
    final look = widget.looks[_page];
    final idx = (look['index'] as num?)?.toInt() ?? _page;
    if (idx < 0 || idx >= widget.photos.length) return;
    final bytes = widget.photos[idx];
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LookEditorScreen(
        imageBytes: bytes,
        cleanImageBytes: bytes, // compare already isolated the cutouts
        score: (look['score'] as num?)?.toInt(),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      // extendBody draws us behind the home indicator — the bottom controls
      // need the inset back (the card itself may bleed edge-to-edge).
      child: SafeArea(
        top: false,
        child: Column(children: [
        Expanded(
          child: PageView.builder(
            controller: _pager,
            itemCount: widget.looks.length,
            onPageChanged: (i) {
              HapticFeedback.selectionClick();
              setState(() => _page = i);
            },
            itemBuilder: (_, i) => _card(widget.looks[i], i),
          ),
        ),
        // Dots.
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < widget.looks.length; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == _page ? 16 : 6, height: 6,
                decoration: BoxDecoration(
                    color: i == _page ? Colors.white : Colors.white24, borderRadius: BorderRadius.circular(999)),
              ),
          ]),
        ),
        // Smart Commerce ONLY when the whole set failed — the honest answer
        // to "none of these work", never an upsell against our own winner.
        if (kCommerce && _allWeak) _SmartCommerce(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
          child: Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _improve,
                icon: const Icon(Icons.auto_fix_high, size: 17),
                label: const Text('Improve this look',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
            const SizedBox(width: 10),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
              onPressed: widget.onReset,
              child: Text('compare.tryAgain'.tr(), style: const TextStyle(fontSize: 13)),
            ),
          ]),
        ),
      ]),
      ),
    );
  }

  Widget _card(Map<String, dynamic> look, int rank) {
    final idx = ((look['index'] as num?) ?? 0).toInt().clamp(0, widget.photos.length - 1);
    final score = ((look['score'] as num?) ?? 0).toInt();
    final title = (look['title'] ?? '').toString();
    // Structured evaluation: 2-3 punchy bullets from the backend; legacy
    // paragraph answers degrade into sentence-split bullets.
    final rawBullets = (look['why_bullets'] as List?)?.map((e) => e.toString()).toList();
    final bullets = (rawBullets == null || rawBullets.isEmpty)
        ? (look['why'] ?? '')
            .toString()
            .split(RegExp(r'(?<=[.!?])\s+'))
            .where((s) => s.trim().isNotEmpty)
            .map((s) => s.replaceAll(RegExp(r'\.$'), ''))
            .take(3)
            .toList()
        : rawBullets.take(3).toList();
    final winner = rank == 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 14, 6, 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.hero),
        child: LayoutBuilder(
          builder: (_, cons) => Stack(fit: StackFit.expand, children: [
            // LIGHT studio: white center with a barely-warm edge falloff. On
            // white, any residual mask fringe is invisible by definition —
            // and it matches the editor's studio register.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0, -0.2),
                  radius: 1.2,
                  colors: [Color(0xFFFFFFFF), Color(0xFFF6F6F4), Color(0xFFECECE9)],
                  stops: [0.0, 0.6, 1.0],
                ),
              ),
            ),
            // Figure pulled back (~86% of card height): less upscaling =
            // sharper edges, plus breathing room around the silhouette.
            Padding(
              padding: EdgeInsets.symmetric(
                  vertical: cons.maxHeight * 0.07, horizontal: cons.maxWidth * 0.06),
              child: Stack(fit: StackFit.expand, children: [
                // Floor-contact shadow under the feet.
                Align(
                  alignment: const Alignment(0, 1.0),
                  child: Container(
                    width: cons.maxWidth * 0.44,
                    height: 22,
                    decoration: const BoxDecoration(
                      gradient: RadialGradient(
                        colors: [Color(0x30000000), Color(0x00000000)],
                      ),
                      borderRadius: BorderRadius.all(Radius.elliptical(180, 22)),
                    ),
                  ),
                ),
                // Soft silhouette drop shadow — grey on the light studio.
                Transform.translate(
                  offset: const Offset(8, 10),
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: ColorFiltered(
                      colorFilter: const ColorFilter.matrix([
                        0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0,
                        0, 0, 0, 0.22, 0,
                      ]),
                      child: Image.memory(widget.photos[idx],
                          fit: BoxFit.fitHeight,
                          alignment: Alignment.center,
                          gaplessPlayback: true),
                    ),
                  ),
                ),
                Image.memory(widget.photos[idx],
                    fit: BoxFit.fitHeight,
                    alignment: Alignment.center,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.high,
                    isAntiAlias: true),
              ]),
            ),
            // Badge — gold for the winner, quiet glass for runners-up.
            Positioned(
              top: 14, left: 14,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    color: winner ? const Color(0xE60A0A0A) : const Color(0x66000000),
                    child: Text(
                      winner
                          ? 'compare.topPick'.tr(args: ['$score'])
                          : 'compare.place'.tr(args: ['${rank + 1}', '$score']),
                      style: TextStyle(
                          color: winner ? const Color(0xFFFFD54F) : Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3),
                    ),
                  ),
                ),
              ),
            ),
            // Verdict panel: seamless fade-to-black over the figure's feet. The
            // WHY is NEVER truncated — long reads scroll inside the panel.
            Positioned(
              left: 0, right: 0, bottom: 0,
              child: Container(
                // Feet protection: at most a third of the card, near-
                // transparent through its upper half — solid WHITE only over
                // the bottom slice.
                constraints: BoxConstraints(maxHeight: cons.maxHeight * 0.34),
                padding: const EdgeInsets.fromLTRB(18, 30, 18, 16),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00FFFFFF), Color(0x59FFFFFF), Color(0xE6FFFFFF), Color(0xFAFFFFFF)],
                    stops: [0.0, 0.42, 0.72, 1.0],
                  ),
                ),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (title.isNotEmpty)
                        Text(title,
                            style: const TextStyle(
                                color: AppColors.ink, fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                      const SizedBox(height: 6),
                      Text('compare.whyTitle'.tr(),
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 2)),
                      const SizedBox(height: 6),
                      // Scannable bullets: glowing accent dot + one punchy line
                      // each — never a wall of text.
                      Flexible(
                        child: SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var i = 0; i < bullets.length; i++) ...[
                                if (i > 0) const SizedBox(height: 8),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 7, height: 7,
                                      margin: const EdgeInsets.only(top: 5.5, right: 10),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: AppColors.signature,
                                        boxShadow: [
                                          BoxShadow(
                                              color: AppColors.signature.withValues(alpha: 0.45),
                                              blurRadius: 7),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(bullets[i],
                                          style: const TextStyle(
                                              color: AppColors.inkSoft,
                                              fontSize: 13.5,
                                              height: 1.35)),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// "None of these earn a spot — these would work better" — real items from the
/// affiliate catalogue, Shop opens the partner link externally.
class _SmartCommerce extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: ref.read(looktokApiProvider).affiliateAlternatives(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Shimmer(child: ShimmerBox(height: 54, radius: 12)),
          );
        }
        final items = snap.data ?? const [];
        if (items.isEmpty) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: const Color(0xFF161616),
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('compare.ctaTitle'.tr(),
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
            const SizedBox(height: 2),
            Text('compare.ctaLead'.tr(), style: const TextStyle(color: Colors.white54, fontSize: 12.5)),
            const SizedBox(height: 10),
            for (final a in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(children: [
                  Expanded(
                    child: Text('${a['brand_name']} — ${a['name']}',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                  Text('${a['currency'] ?? 'USD'} ${a['price'] ?? ''}',
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: () => launchUrl(Uri.parse((a['buy_url'] ?? '').toString()),
                        mode: LaunchMode.externalApplication),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999)),
                      child: Text('common.shop'.tr(),
                          style: const TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.w800)),
                    ),
                  ),
                ]),
              ),
          ]),
        );
      },
    );
  }
}

/// Compare-mode selector card: soft white, cobalt when active.
class _ModeCard extends StatelessWidget {
  const _ModeCard(
      {required this.on,
      required this.title,
      required this.caption,
      required this.icon,
      required this.onTap});
  final bool on;
  final String title, caption;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: on ? AppColors.ink : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: on ? AppColors.ink : AppColors.line),
        ),
        child: Row(children: [
          Icon(icon, size: 19, color: on ? AppColors.signature : AppColors.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                      color: on ? Colors.white : AppColors.ink)),
              Text(caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      color: on ? Colors.white70 : AppColors.muted)),
            ]),
          ),
        ]),
      ),
    );
  }
}
