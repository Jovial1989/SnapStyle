import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:easy_localization/easy_localization.dart';

import 'dart:async' show Timer;
import 'dart:convert' show base64Encode;
import 'package:flutter/foundation.dart' show listEquals, compute;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../utils/autocrop.dart';
import '../utils/webp_payload.dart';
import '../models/subject.dart';
import '../providers.dart';
import '../services/analytics.dart';
import '../services/api_client.dart' show PaywallRequired;
import '../flags.dart';
import '../theme.dart';
import 'select_looks_screen.dart';
import '../widgets/subject_sheet.dart';
import '../widgets/moodboard_loader.dart';
import '../widgets/shimmer.dart';

/// Journey B result: restyle the user's photo into 3–4 occasion looks (Gemini
/// image, synchronous) to choose from. The user KEEPS the one they like (the
/// rest are discarded) or drops the whole set. Inspiration only — never shoppable.
class LookGenScreen extends ConsumerStatefulWidget {
  const LookGenScreen(
      {super.key,
      required this.photoPath,
      required this.occasion,
      this.source = 'inspire',
      this.subject = const Subject.me()});
  final String photoPath;
  final String occasion;
  final String source;
  final Subject subject; // whose look — carries the guest body + name (§14.10)

  @override
  ConsumerState<LookGenScreen> createState() => _LookGenScreenState();
}

class _LookGenScreenState extends ConsumerState<LookGenScreen> {
  // ASYNC fan-out: the dispatcher returns per-look render row ids in seconds;
  // _RenderFlow then watches the rows over Supabase Realtime.
  Future<({String id, List<Map<String, dynamic>> renders})>? _dispatch;
  // Archetype "muse" feed shown while the set dispatches (fetched once). Never throws.
  late final Future<List<Map<String, dynamic>>> _muses = ref.read(looktokApiProvider).museFeed(occasion: widget.occasion);

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _run() {
    Analytics.generationStarted(
        tier: (ref.read(entitlementProvider).valueOrNull?['pro'] == true)
            ? 'pro'
            : 'free');
    setState(() {
      _dispatch = ref.read(looktokApiProvider).dispatchLooks(
          photoPath: widget.photoPath,
          event: widget.occasion,
          source: widget.source,
          bodyOverride: widget.subject.toOverride());
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<({String id, List<Map<String, dynamic>> renders})>(
      future: _dispatch,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          // IMMERSIVE loader: its own pitch-black Scaffold drawn edge-to-edge
          // (no SafeArea → no white bars), light status-bar icons, the user's
          // CLEAN cutout breathing over the ambient muse moodboard.
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light,
            child: Scaffold(
              backgroundColor: Colors.black,
              extendBodyBehindAppBar: true,
              extendBody: true,
              appBar: AppBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  foregroundColor: Colors.white),
              body: MoodboardLoader(
                images: _muses,
                occasion: widget.occasion,
                thoughts: [
                  'gen.working1'.tr(),
                  'gen.working2'.tr(args: [widget.occasion]),
                  'gen.working3'.tr(),
                  'gen.working4'.tr(),
                ],
              ),
            ),
          );
        }
        if (snap.hasError || (snap.data?.renders.isEmpty ?? true)) {
          return Scaffold(
            appBar: AppBar(title: Text('gen.title'.tr(args: [widget.occasion]))),
            body: SafeArea(child: _Failed(error: snap.error, onRetry: _run)),
          );
        }
        // Dispatched: hand over to the reactive fan-out stage — skeleton grid
        // whose cards flip independently as each worker's row lands, then the
        // gallery once every render is terminal.
        return _RenderFlow(
          id: snap.data!.id,
          renders: snap.data!.renders,
          occasion: widget.occasion,
          subject: widget.subject,
          onRetry: _run,
        );
      },
    );
  }
}

/// Reactive fan-out stage (Supabase Realtime): one skeleton card per
/// dispatched render; each flips to its image INDEPENDENTLY the moment its
/// worker's row goes completed. All rows terminal → auto-advance to the
/// gallery (or the shared error state when the whole set died).
class _RenderFlow extends ConsumerStatefulWidget {
  const _RenderFlow(
      {required this.id,
      required this.renders,
      required this.occasion,
      required this.subject,
      required this.onRetry});
  final String id;
  final List<Map<String, dynamic>> renders; // dispatch order: {id,index,tier,title}
  final String occasion;
  final Subject subject;
  final VoidCallback onRetry;
  @override
  ConsumerState<_RenderFlow> createState() => _RenderFlowState();
}

class _RenderFlowState extends ConsumerState<_RenderFlow> {
  late final Stream<List<Map<String, dynamic>>> _stream = ref
      .read(looktokApiProvider)
      .lookRenders([for (final r in widget.renders) (r['id'] ?? '').toString()]);
  bool _credited = false;
  // EARLY ENTRY: a ready card is tappable — the gallery opens with whatever
  // exists and live-updates as the rest arrive. Completed looks are ordered by
  // ARRIVAL (append-only), so pages never shift under the user mid-swipe.
  final List<String> _arrival = []; // completed row ids, first-seen order

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        final byId = {
          for (final r in snap.data ?? const <Map<String, dynamic>>[])
            (r['id'] ?? '').toString(): r,
        };
        // Rows in dispatch order; null until the first Realtime snapshot.
        final rows = [
          for (final r in widget.renders) byId[(r['id'] ?? '').toString()],
        ];
        final terminal = snap.hasData &&
            rows.every((r) => r != null && r['status'] != 'pending');
        final completed = [
          for (final r in rows)
            if (r != null &&
                r['status'] == 'completed' &&
                (r['image_path'] ?? '').toString().isNotEmpty)
              r,
        ];

        for (final r in completed) {
          final id = (r['id'] ?? '').toString();
          if (!_arrival.contains(id)) _arrival.add(id);
        }
        final ordered = [
          for (final id in _arrival)
            completed.firstWhere((r) => (r['id'] ?? '').toString() == id,
                orElse: () => const <String, dynamic>{}),
        ].where((r) => r.isNotEmpty).toList();

        if (ordered.isNotEmpty) {
          if (terminal && !_credited) {
            _credited = true; // the last worker burned the set's credit
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) ref.invalidate(entitlementProvider);
            });
          }
          final paths = [for (final r in ordered) r['image_path'].toString()];
          final looks = [
            for (final r in ordered)
              () {
                final meta =
                    ((r['meta'] as Map?)?.cast<String, dynamic>()) ?? const <String, dynamic>{};
                return <String, dynamic>{
                  'image_path': r['image_path'],
                  'tier': meta['tier'],
                  'title': meta['title'],
                  'wardrobe_used': meta['wardrobe_used'] ?? const [],
                  'kept_from_photo': meta['kept_from_photo'] ?? const [],
                  'affiliate': meta['affiliate'] ?? const [],
                };
              }(),
          ];
          // Result: the title lives in a SOLID app bar ABOVE the image
          // container — outside the avatar Stack, so it can never overlap the
          // face. Solid white on white imagery keeps contrast without a pill.
          return Scaffold(
            backgroundColor: const Color(0xFFFFFFFF),
            appBar: AppBar(
              backgroundColor: const Color(0xFFFFFFFF),
              foregroundColor: AppColors.ink,
              elevation: 0,
              title: Text('gen.title'.tr(args: [widget.occasion]),
                  style: const TextStyle(
                      color: AppColors.ink, fontSize: 16, fontWeight: FontWeight.w800)),
            ),
            body: _Gallery(
              id: widget.id,
              paths: paths,
              looks: looks,
              occasion: widget.occasion,
              subject: widget.subject,
              onRetry: widget.onRetry,
              settled: terminal,
              initialIndex: 0,
            ),
          );
        }

        if (terminal && completed.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: Text('gen.title'.tr(args: [widget.occasion]))),
            body: SafeArea(child: _Failed(error: null, onRetry: widget.onRetry)),
          );
        }

        // ── Waiting for the FIRST look: the SAME white gallery frame with a
        // breathing skeleton card — NO separate atelier loader screen (owner
        // call). The moment a render lands, the branch above swaps the skeleton
        // for the real look inside the identical frame. ──
        return Scaffold(
          backgroundColor: const Color(0xFFFFFFFF),
          appBar: AppBar(
            backgroundColor: const Color(0xFFFFFFFF),
            foregroundColor: AppColors.ink,
            elevation: 0,
            title: Text('gen.title'.tr(args: [widget.occasion]),
                style: const TextStyle(
                    color: AppColors.ink, fontSize: 16, fontWeight: FontWeight.w800)),
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 90),
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: const Color(0xFFECEAE4)),
                  boxShadow: const [
                    BoxShadow(color: Color(0x1F000000), blurRadius: 34, offset: Offset(0, 16)),
                  ],
                ),
                child: const _CardSkeleton(),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One look's card in the fan-out grid — FAULT-ISOLATED: it manages its own
/// watchdog and failure state, so one dead render never breaks the rest.
/// Shimmer while pending; flips to the image when ITS row completes; a
/// "didn't land / taking too long" placeholder with a per-card Retry after a
/// `failed` status OR 25s of local silence (zombie-loading protection).
class _RenderCard extends ConsumerStatefulWidget {
  const _RenderCard(
      {required this.row, required this.title, required this.index, required this.onRetry});
  final Map<String, dynamic>? row; // null until the first stream snapshot
  final String title;
  final int index;
  final VoidCallback onRetry; // re-dispatches JUST this render
  @override
  ConsumerState<_RenderCard> createState() => _RenderCardState();
}

class _RenderCardState extends ConsumerState<_RenderCard> {
  Future<String>? _url; // memoized signed URL — stable across rebuilds
  Timer? _watchdog;
  bool _timedOut = false;

  String get _status => (widget.row?['status'] ?? 'pending').toString();

  @override
  void initState() {
    super.initState();
    _arm();
  }

  void _arm() {
    _watchdog?.cancel();
    _timedOut = false;
    _watchdog = Timer(const Duration(seconds: 25), () {
      if (mounted && _status == 'pending') setState(() => _timedOut = true);
    });
  }

  @override
  void didUpdateWidget(covariant _RenderCard old) {
    super.didUpdateWidget(old);
    final s = _status;
    final prev = (old.row?['status'] ?? 'pending').toString();
    if (s != 'pending') _watchdog?.cancel();
    // failed→pending (a retry, from this device or another) re-arms the clock.
    if (s == 'pending' && prev != 'pending') _arm();
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    super.dispose();
  }

  void _retry() {
    HapticFeedback.selectionClick();
    widget.onRetry(); // fire-and-forget; Realtime carries the row transitions
    setState(_arm); // optimistic: back to the shimmer, fresh 25s clock
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final path = (widget.row?['image_path'] ?? '').toString();

    Widget child;
    if (status == 'completed' && path.isNotEmpty) {
      // Light 600px transform thumb; if the transform endpoint rejects it
      // (add-on off), errorBuilder falls back to the raw asset.
      final api = ref.read(looktokApiProvider);
      _url ??= api.lookThumbUrl(path);
      child = FutureBuilder<String>(
        future: _url,
        builder: (_, s) => s.hasData
            ? Image.network(s.data!,
                fit: BoxFit.cover, width: double.infinity, height: double.infinity,
                gaplessPlayback: true,
                loadingBuilder: (_, w, p) => p == null ? w : const _CardSkeleton(),
                errorBuilder: (_, _, _) => _FullSizeFallback(path: path))
            : const _CardSkeleton(),
      );
    } else if (status == 'failed' || (_timedOut && status == 'pending')) {
      final timedOut = status == 'pending';
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _retry,
        child: ColoredBox(
          color: const Color(0xFF161616),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Delicate thin-stroke refresh ring.
              Container(
                width: 44, height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.28), width: 1),
                ),
                child: const Icon(Icons.refresh_rounded,
                    color: Colors.white70, size: 19),
              ),
              const SizedBox(height: 12),
              Text(timedOut ? 'TIMEOUT' : 'DIDN’T LAND',
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2.2)),
              const SizedBox(height: 10),
              // Glass retry pill — the refined, obvious touch cue.
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.16)),
                    ),
                    child: const Text('Tap to retry',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ]),
          ),
        ),
      );
    } else {
      child = const _CardSkeleton();
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(fit: StackFit.expand, children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (c, anim) => FadeTransition(opacity: anim, child: c),
          child: KeyedSubtree(key: ValueKey('$status-$path-$_timedOut'), child: child),
        ),
        if (status == 'completed')
          Positioned(
            top: 8, right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                  color: const Color(0xB3000000),
                  borderRadius: BorderRadius.circular(999)),
              child: const Text('VIEW',
                  style: TextStyle(
                      color: Colors.white, fontSize: 9,
                      fontWeight: FontWeight.w800, letterSpacing: 1.4)),
            ),
          ),
        Positioned(
          left: 10, right: 10, bottom: 8,
          child: Text(
            widget.title.isEmpty ? 'Look ${widget.index + 1}' : widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: status == 'completed' ? Colors.white : Colors.white38,
              fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1.2,
              shadows: status == 'completed'
                  ? const [Shadow(color: Color(0xAA000000), blurRadius: 8)]
                  : const [],
            ),
          ),
        ),
      ]),
    );
  }
}

/// Fallback when the 600px transform URL is rejected (Image Transformation
/// add-on off or transient CDN error): load the raw asset instead.
class _FullSizeFallback extends ConsumerStatefulWidget {
  const _FullSizeFallback({required this.path});
  final String path;
  @override
  ConsumerState<_FullSizeFallback> createState() => _FullSizeFallbackState();
}

class _FullSizeFallbackState extends ConsumerState<_FullSizeFallback> {
  Future<String>? _url;
  @override
  Widget build(BuildContext context) {
    _url ??= ref.read(looktokApiProvider).lookImageUrl(widget.path);
    return FutureBuilder<String>(
      future: _url,
      builder: (_, s) => s.hasData
          ? Image.network(s.data!,
              fit: BoxFit.cover, width: double.infinity, height: double.infinity,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const _CardSkeleton())
          : const _CardSkeleton(),
    );
  }
}

/// Dark skeleton with the shimmer sweep + a ghost hanger — reads as "styling
/// in progress", never as a broken tile.
/// Soft "breathing" skeleton: rich matte grey pulsing 0.6 ↔ 1.0 with a gently
/// pulsing hanger — no high-contrast shimmer sweeps.
class _CardSkeleton extends StatefulWidget {
  const _CardSkeleton();
  @override
  State<_CardSkeleton> createState() => _CardSkeletonState();
}

class _CardSkeletonState extends State<_CardSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _breath, curve: Curves.easeInOut);
    return FadeTransition(
      opacity: Tween(begin: 0.6, end: 1.0).animate(curve),
      child: ColoredBox(
        color: const Color(0xFF1A1A1A),
        child: Center(
          child: FadeTransition(
            opacity: Tween(begin: 0.35, end: 1.0).animate(curve),
            child: Icon(Icons.checkroom,
                color: Colors.white.withValues(alpha: 0.14), size: 32),
          ),
        ),
      ),
    );
  }
}

/// Big selected look + thumbnail strip; Keep the pick or drop the set.
class _Gallery extends ConsumerStatefulWidget {
  const _Gallery(
      {required this.id, required this.paths, required this.looks,
      required this.occasion, required this.subject, required this.onRetry,
      this.settled = true, this.initialIndex = 0});
  final List<Map<String, dynamic>> looks; // per-look tier metadata (affiliate items)
  final String id;
  final List<String> paths;
  final String occasion;
  final Subject subject;
  final VoidCallback onRetry;
  // false = early entry: more looks are still ARRIVING (paths grow append-only)
  // and destructive actions (keep/delete trim the set) stay disabled.
  final bool settled;
  final int initialIndex;
  @override
  ConsumerState<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends ConsumerState<_Gallery> {
  late int _sel = widget.initialIndex;

  /// Affiliate items linked to the currently selected look (empty = pure AI look).
  List<Map<String, dynamic>> get _selAffiliate {
    for (final l in widget.looks) {
      if (l['image_path'] == widget.paths[_sel]) {
        return ((l['affiliate'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      }
    }
    return const [];
  }

  /// Closet mode: essential slots the wardrobe couldn't cover for the selected
  /// look — those were kept from the user's own photo, never invented.
  List<String> get _selKeptFromPhoto {
    for (final l in widget.looks) {
      if (l['image_path'] == widget.paths[_sel]) {
        return ((l['kept_from_photo'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList();
      }
    }
    return const [];
  }

  Future<void> _shop(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Couldn’t open the store link')));
      }
    }
  }
  bool _busy = false;
  String? _guestName; // captured once when a guest's set is ready (§14.10)
  // Memoize the signed-URL future per path. Without this, every setState (tapping
  // a look) rebuilds _img with a fresh future → all tiles flash blank while they
  // re-resolve. Stable futures keep the images on screen.
  final Map<String, Future<String>> _urlCache = {};
  Future<String> _url(String p) =>
      _urlCache[p] ??= ref.read(looktokApiProvider).lookImageUrl(p);

  // Fetch the look bytes and auto-crop the studio margins, so the person fills
  // the frame on a clean WHITE backing (the render's own grey backdrop is
  // trimmed away). Cached per path — one fetch/crop each.
  final Map<String, Future<Uint8List>> _bytesCache = {};
  Future<Uint8List> _bytes(String p) => _bytesCache[p] ??= _url(p).then((url) async {
        final res = await http.get(Uri.parse(url));
        return compute(autoCropSubject, res.bodyBytes);
      });

  @override
  void didUpdateWidget(covariant _Gallery old) {
    super.didUpdateWidget(old);
    if (!listEquals(old.paths, widget.paths)) {
      // Early-entry growth is APPEND-ONLY (arrival order): new looks slide in
      // at the end, so keep the user's page and every warm cache. Only a truly
      // different set (Try another set) resets.
      final grew = widget.paths.length > old.paths.length &&
          listEquals(widget.paths.sublist(0, old.paths.length), old.paths);
      if (!grew) {
        _urlCache.clear();
        _bytesCache.clear();
        _sel = 0;
        if (_pager.hasClients) _pager.jumpToPage(0);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    HapticFeedback.mediumImpact(); // looks are ready
    // A guest's auto-saved set needs a name so history reads "Victoria's look".
    if (widget.subject.isGuest && widget.subject.name == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _nameGuest());
    }
  }

  Future<void> _nameGuest() async {
    final name = (await promptSubjectName(context))?.trim();
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _guestName = name);
    try {
      await ref.read(looktokApiProvider).nameGeneration(widget.id, name);
    } catch (_) {/* best-effort */}
  }

  bool _rated = false;

  /// Walking away without keeping a look = a taste signal we must not lose.
  /// One 5-star sheet; ≤3 stars → offer the preference-upload flow (photos of
  /// outfits they love — on them or anyone — feed style_dna).
  Future<void> _maybeRate(VoidCallback proceed) async {
    if (_rated || !widget.settled) {
      proceed();
      return;
    }
    final rating = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.bg,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Rate this set',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const Text('Nothing you\'d wear? Tell us — it tunes your next sets.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted, fontSize: 13.5)),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    iconSize: 40,
                    onPressed: () => Navigator.pop(context, i),
                    icon: const Icon(Icons.star_border_rounded,
                        color: AppColors.signature),
                  ),
              ],
            ),
          ]),
        ),
      ),
    );
    if (!mounted) return;
    if (rating != null) {
      _rated = true;
      HapticFeedback.selectionClick();
      try {
        await ref.read(looktokApiProvider).rateLookSet(widget.id, rating);
      } catch (_) {/* feedback is best-effort */}
      if (!mounted) return;
      if (rating <= 3) {
        final go = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            icon: const Icon(Icons.auto_awesome, size: 28, color: AppColors.signature),
            title: const Text('Teach it your taste'),
            content: const Text(
                'Upload a few photos of outfits you actually love — on you or '
                'on anyone whose style you\'d wear. Your next sets are built '
                'from that.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(d, false),
                  child: const Text('Not now')),
              FilledButton(
                  onPressed: () => Navigator.pop(d, true),
                  child: const Text('Upload my style')),
            ],
          ),
        );
        if (!mounted) return;
        if (go == true) {
          await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SelectLooksScreen()));
          if (!mounted) return;
        }
      }
    }
    proceed();
  }

  /// Keep the selected look (trim the set to it) and return to My Looks.
  Future<void> _keep() async {
    setState(() => _busy = true);
    try {
      await ref.read(looktokApiProvider).keepLook(
            widget.id,
            keepPath: widget.paths[_sel],
            allPaths: widget.paths,
            subjectName: widget.subject.name ?? _guestName,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Saved to My Looks')));
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeSet() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove these looks?'),
        content: const Text('They’ll be deleted from My Looks.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(looktokApiProvider).deleteLook(widget.id, imagePaths: widget.paths);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  Widget _img(String path, {BoxFit fit = BoxFit.cover, Alignment align = Alignment.center}) => FutureBuilder<Uint8List>(
        future: _bytes(path),
        builder: (_, s) => s.connectionState == ConnectionState.done && s.hasData
            ? Image.memory(s.data!, fit: fit, alignment: align, width: double.infinity, height: double.infinity, gaplessPlayback: true)
            : const ColoredBox(color: Color(0xFFFFFFFF)),
      );

  late final _pager = PageController(initialPage: widget.initialIndex);

  // ── Generated flat-lays for imageless SKUs ─────────────────────────────
  // Demo affiliate items carry placehold.co text tiles — real product photos
  // arrive only with live feeds. Until then, extract the garment FROM THE
  // RENDER ITSELF (same EF as the editor thumbnails): the card then shows the
  // piece exactly as worn — same color, same material — so it can never
  // contradict the avatar. Cached app-wide, keyed per look render + SKU.
  static final Map<String, Future<Uint8List>> _flatLays = {};

  Future<Uint8List> _flatLay(String lookPath, Map<String, dynamic> a) {
    final key = '$lookPath|${a['brand']}|${a['name']}';
    final existing = _flatLays[key];
    if (existing != null) return existing;
    final fut = () async {
      final api = ref.read(looktokApiProvider);
      final src = await toWebPPayload(await _bytes(lookPath));
      final out = await api.generateItem(
        base64Image: base64Encode(src),
        mimeType: imageMime(src),
        instruction: 'From this photo, isolate EXACTLY ONE garment — the '
            '${a['name']} by ${a['brand']} the person is WEARING — and present '
            'it ALONE as a professional e-commerce product shot on a pure white '
            'background: IDENTICAL color, material and details to how it '
            'appears on the person. No person, no mannequin, no other '
            'garments, no collage, no text.',
      );
      try {
        return await compute(autoCropSubject, out);
      } catch (_) {
        return out;
      }
    }();
    _flatLays[key] = fut;
    // Evict failures so a flaky network gets a fresh attempt next build.
    fut.then((_) {}, onError: (_) => _flatLays.remove(key));
    return fut;
  }

  // ── Interactive Sync (two-way) ─────────────────────────────────────────
  // Single source of truth for "which garment is in focus": hotspot taps and
  // manual carousel scrolls both funnel into it; hotspots + cards listen.
  final ValueNotifier<int> _activeItem = ValueNotifier(0);
  late final PageController _products = PageController(viewportFraction: 0.46)
    ..addListener(() {
      final p = (_products.hasClients ? (_products.page ?? 0) : 0.0).round();
      if (p != _activeItem.value) _activeItem.value = p; // scroll → hotspot
    });

  @override
  void dispose() {
    _pager.dispose();
    _products.dispose();
    _activeItem.dispose();
    super.dispose();
  }

  /// Hotspot tap → snap the carousel to that card (dot → list direction).
  void _focusItem(int i) {
    HapticFeedback.selectionClick();
    _activeItem.value = i;
    if (_products.hasClients) {
      _products.animateToPage(i,
          duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    }
  }

  // Hotspots are positioned in DISPLAYED-IMAGE coordinates, not card
  // coordinates: renders are auto-cropped tight to the person, so fractions
  // of the visible image rect are body-relative ("normalized joints"). The
  // old Align()-on-the-card approach ignored BoxFit.contain letterboxing —
  // that was the "dot floating in empty space" bug.
  static const _zoneFractions = {
    'top': Offset(0.38, 0.24), // left chest — clear of the mirror phone (always center)
    'outerwear': Offset(0.70, 0.34), // the open layer's panel, right side
    'bottom': Offset(0.44, 0.62),
    'shoes': Offset(0.50, 0.88),
    'accessory': Offset(0.66, 0.44), // wrist-ish
  };

  /// A product's body zone: the catalogue category when the backend sent it
  /// (exact), else inferred from the name (older saved sets). Duplicate zones
  /// nudge downward and alternate label sides so annotations never collide.
  static String _zoneOfItem(Map<String, dynamic> item) {
    final cat = (item['category'] ?? '').toString().toLowerCase();
    if (_zoneFractions.containsKey(cat)) return cat;
    final t = ('${item['name']} ${item['brand']}').toLowerCase();
    if (RegExp(r'shoe|sneaker|trainer|boot|loafer|sandal|samba|runner|court')
        .hasMatch(t)) {
      return 'shoes';
    }
    if (RegExp(r'overshirt|jacket|coat|blazer|cardigan|hoodie|parka|bomber|gilet')
        .hasMatch(t)) {
      return 'outerwear';
    }
    if (RegExp(r'short|pant|trouser|jean|chino|skirt').hasMatch(t)) return 'bottom';
    if (RegExp(r'watch|belt|bag|scarf|hat|cap|glasses|jewel|sock').hasMatch(t)) {
      return 'accessory';
    }
    return 'top';
  }

  // Per-path aspect ratio of the auto-cropped render — needed to compute the
  // BoxFit.contain rect the dots are laid out in.
  final Map<String, double> _aspectCache = {};
  void _resolveAspect(String p) {
    if (_aspectCache.containsKey(p)) return;
    _bytes(p).then((b) async {
      final im = await decodeImageFromList(b);
      _aspectCache[p] = im.width / im.height;
      im.dispose();
      if (mounted) setState(() {});
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    // Immersive shoppable look: full-bleed avatar with glass hotspots on the
    // garments + a frosted bottom panel holding a center-scaled 3:4 product
    // carousel. Hotspots and carousel are two-way synced via _activeItem.
    // Commerce parked: an empty affiliate list collapses the SHOP panel, the
    // price callouts and the hotspots in one stroke.
    final affiliate = kCommerce ? _selAffiliate : const <Map<String, dynamic>>[];
    // Clear the home indicator with a real floor. Use viewPadding (the TRUE
    // physical inset — NOT consumed by an ancestor SafeArea, which is why
    // padding.bottom kept reading ~0 here and the Keep button clipped).
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom.clamp(20.0, 48.0);
    // Leaving without keeping a look → the rating gate fires first (once).
    return PopScope(
      canPop: _rated || !widget.settled,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _maybeRate(() {
          if (mounted) Navigator.of(context).pop();
        });
      },
      child: Stack(children: [

      // ── STATIC studio set: radial backdrop + floor shadow. They never move
      // during swipes — only the look itself slides (buttery constraint). The
      // gradient also masks cutout artifacts the harsh white used to expose. ──
      const Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.2),
              radius: 1.3,
              colors: [Color(0xFFF7F7F9), Color(0xFFF0F0F3), Color(0xFFE5E5EA)],
              stops: [0.0, 0.55, 1.0],
            ),
          ),
        ),
      ),
      // Gravity: a blurred floor ellipse under the figure — the person stands
      // on something instead of floating in a void.
      Positioned(
        left: 0, right: 0,
        bottom: (affiliate.isEmpty ? 90 : 268) + 6,
        child: IgnorePointer(
          child: Center(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 10),
              child: Container(
                width: MediaQuery.of(context).size.width * 0.52,
                height: 22,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: const Color(0x2E000000),
                ),
              ),
            ),
          ),
        ),
      ),

      // ── Full-bleed hero, swipeable between the looks ─────────────────────
      Positioned.fill(
        child: PageView.builder(
          controller: _pager,
          itemCount: widget.paths.length,
          onPageChanged: (i) {
            HapticFeedback.selectionClick();
            setState(() => _sel = i);
            _activeItem.value = 0;
            if (_products.hasClients) _products.jumpToPage(0);
          },
          itemBuilder: (_, i) {
            final path = widget.paths[i];
            _resolveAspect(path);
            return Stack(fit: StackFit.expand, children: [
            // Bottom inset keeps the figure clear of the frosted panel. Dots
            // live INSIDE this padded area, mapped to the contain-fitted
            // image rect — they track the body, not the card.
            Padding(
              padding: EdgeInsets.only(
                  bottom: affiliate.isEmpty ? 90 : 268, top: 4),
              child: LayoutBuilder(builder: (_, box) {
                // The contain-fitted rect of the auto-cropped render — callout
                // dots are laid out in ITS coordinates so they track the body.
                Rect? imgRect() {
                  final aspect = _aspectCache[path];
                  if (aspect == null || box.maxWidth == 0 || box.maxHeight == 0) return null;
                  var rw = box.maxWidth;
                  var rh = rw / aspect;
                  if (rh > box.maxHeight) {
                    rh = box.maxHeight;
                    rw = rh * aspect;
                  }
                  return Rect.fromLTWH(
                      (box.maxWidth - rw) / 2, (box.maxHeight - rh) / 2, rw, rh);
                }

                final rect = imgRect();
                final seen = <String, int>{};
                return Stack(fit: StackFit.expand, children: [
                  // FASHION FRAME: the look sits in a rounded white card. CONTAIN
                  // (never cover) — the whole figure stays visible, head AND
                  // feet; the card's white hides the letterbox. Cover was
                  // zooming in and cropping the head/feet.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: const Color(0xFFECEAE4)),
                        boxShadow: const [
                          BoxShadow(color: Color(0x1F000000), blurRadius: 34, offset: Offset(0, 16)),
                        ],
                      ),
                      child: _img(path, fit: BoxFit.contain),
                    ),
                  ),
                  if (i == _sel && rect != null)
                    for (var d = 0; d < affiliate.length && d < 4; d++)
                      Builder(builder: (_) {
                        final zone = _zoneOfItem(affiliate[d]);
                        final dup = seen.update(zone, (v) => v + 1, ifAbsent: () => 0);
                        final base = _zoneFractions[zone]!;
                        // Duplicate zones stack downward; sides alternate so
                        // the edge labels never collide.
                        final fy = (base.dy + dup * 0.09).clamp(0.05, 0.95);
                        final dotX = rect.left + base.dx * rect.width;
                        // Keep the whole 48px band on-screen: an unclamped
                        // shoes dot near the image's bottom edge pushed its
                        // label under the SHOP THIS LOOK panel (invisible +
                        // untappable).
                        final dotY = (rect.top + fy * rect.height)
                            .clamp(26.0, box.maxHeight - 26.0);
                        final toRight = dup.isEven ? base.dx >= 0.5 : base.dx < 0.5;
                        final a = affiliate[d];
                        return Positioned(
                          left: 0, right: 0, top: dotY - 24, height: 48,
                          child: ValueListenableBuilder<int>(
                            valueListenable: _activeItem,
                            builder: (_, active, _) => _Callout(
                              dotX: dotX,
                              toRight: toRight,
                              active: active == d,
                              brand: (a['brand'] ?? '').toString(),
                              price: '${a['currency'] ?? 'USD'} ${a['price'] ?? ''}',
                              onTap: () => _focusItem(d),
                            ),
                          ),
                        );
                      }),
                ]);
              }),
            ),
          ]);
          },
        ),
      ),
      // Static glass counter — top-right, never slides with the pages.
      Positioned(
        top: 12, right: 14,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0x14000000),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
              ),
              child: Text('${_sel + 1}/${widget.paths.length}',
                  style: const TextStyle(
                      color: AppColors.ink, fontSize: 11.5, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ),
      // ── Frosted bottom panel: kicker + product carousel + actions ────────
      Positioned(
        left: 0, right: 0, bottom: 0,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              decoration: const BoxDecoration(
                color: Color(0xE0FFFFFF),
                border: Border(top: BorderSide(color: Colors.white, width: 0.5)),
              ),
              padding: EdgeInsets.fromLTRB(0, 12, 0, bottomInset + 28),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (affiliate.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(children: [
                      Expanded(
                        child: Text('gen.shopThisLook'.tr(),
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.8)),
                      ),
                      // Page dots for the LOOKS.
                      for (var i = 0; i < widget.paths.length; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          margin: const EdgeInsets.symmetric(horizontal: 2.5),
                          width: i == _sel ? 14 : 5, height: 5,
                          decoration: BoxDecoration(
                              color: i == _sel ? AppColors.ink : AppColors.line,
                              borderRadius: BorderRadius.circular(999)),
                        ),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  // Center-scaled 3:4 carousel, snapping — the classic
                  // shoppable rail. Scrolling it drives the hotspots.
                  SizedBox(
                    height: 178,
                    child: AnimatedBuilder(
                      animation: _products,
                      // padEnds MUST stay true: with viewportFraction < 1 and
                      // padEnds:false the LAST card can never scroll into the
                      // center, page.round() never reaches the last index, and
                      // the final item becomes unselectable (the active
                      // hotspot visibly lags the centered card by one).
                      builder: (context, _) => PageView.builder(
                        controller: _products,
                        itemCount: affiliate.length,
                        itemBuilder: (_, i) {
                          final page = _products.hasClients && _products.position.haveDimensions
                              ? (_products.page ?? 0)
                              : 0.0;
                          final delta = (page - i).abs().clamp(0.0, 1.0);
                          final scale = 1.0 - delta * 0.08; // center card pops
                          return Transform.scale(
                            scale: scale,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 5),
                              child: _ProductCard(
                                item: affiliate[i],
                                active: delta < 0.5,
                                flatLay: () => _flatLay(widget.paths[_sel], affiliate[i]),
                                // Tap = local select/preview (syncs the hotspot);
                                // ONLY the explicit bag icon leaves the app.
                                onTap: () => _focusItem(i),
                                onBuy: () => _shop((affiliate[i]['buyUrl'] ?? '').toString()),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                // CLOSET HONESTY: essential slots the wardrobe couldn't cover
                // were kept from the user's own photo — say so plainly instead
                // of quietly inventing a garment.
                if (_selKeptFromPhoto.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Row(children: [
                      const Icon(Icons.info_outline, size: 13, color: AppColors.muted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'No ${_selKeptFromPhoto.join(', ')} in your wardrobe — kept your own.',
                          style: const TextStyle(
                              fontSize: 11.5, color: AppColors.muted,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ]),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
                  child: _actionsRow(),
                ),
              ]),
            ),
          ),
        ),
      ),
    ]));
  }

  Widget _actionsRow() {
    // Keep/delete TRIM the set — disabled during early entry (renders still
    // arriving would race the trim and orphan files). Enabled once settled.
    final canCommit = widget.settled && !_busy;
    Widget round(IconData icon, VoidCallback? onTap, {String? tip}) => Tooltip(
          message: tip ?? '',
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: 48, height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFEEEEEE),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 20,
                  color: onTap == null ? AppColors.line : AppColors.ink),
            ),
          ),
        );
    return Row(children: [
      Expanded(
        child: SizedBox(
          height: 48,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.ink,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
            ),
            onPressed: !canCommit ? null : _keep,
            child: _busy
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text('gen.keepThisLook'.tr(),
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ),
        ),
      ),
      const SizedBox(width: 10),
      round(Icons.refresh_rounded, _busy ? null : () => _maybeRate(widget.onRetry),
          tip: 'gen.tryAnotherSet'.tr()),
      const SizedBox(width: 8),
      round(Icons.delete_outline, !canCommit ? null : _removeSet, tip: 'Delete set'),
    ]);
  }

}

/// Editorial callout — lookbook spec-sheet annotation instead of a price pill
/// sitting on the garment. A small ink dot pins the piece; a hairline runs to
/// the white letterbox margin where BRAND + price live on a white chip. All
/// items are annotated at once (reads like a magazine spread); the active one
/// is full-ink with the price in the signature blue, the rest are ghosted.
class _Callout extends StatelessWidget {
  const _Callout({
    required this.dotX,
    required this.toRight,
    required this.active,
    required this.brand,
    required this.price,
    required this.onTap,
  });
  final double dotX; // dot center, absolute in the band's coordinates
  final bool toRight; // label side: right (true) or left edge
  final bool active;
  final String brand;
  final String price;
  final VoidCallback onTap;

  static const _d = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.translucent,
      child: Stack(children: [
        // Hairline from the garment dot to the edge label.
        Positioned(
          top: 23.5,
          left: toRight ? dotX : 14,
          right: toRight ? 14 : null,
          width: toRight ? null : (dotX - 14).clamp(0.0, double.infinity),
          child: AnimatedContainer(
            duration: _d,
            height: 1,
            color: active ? AppColors.ink : AppColors.line,
          ),
        ),
        // The dot, pinned on the piece itself.
        Positioned(
          left: dotX - 6, top: 18,
          child: AnimatedContainer(
            duration: _d,
            width: 12, height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? AppColors.ink : Colors.white,
              border: Border.all(color: active ? Colors.white : AppColors.ink, width: 1.5),
              boxShadow: const [
                BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 1)),
              ],
            ),
          ),
        ),
        // Edge label on a white chip (masks the hairline's tail).
        Positioned(
          right: toRight ? 10 : null,
          left: toRight ? null : 10,
          top: 4, bottom: 4,
          child: AnimatedOpacity(
            duration: _d,
            opacity: active ? 1 : 0.5,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              color: Colors.white,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment:
                    toRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  Text(brand.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 9.5, fontWeight: FontWeight.w800,
                          letterSpacing: 1.6, color: AppColors.ink)),
                  const SizedBox(height: 1),
                  Text(price,
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w800,
                          color: active ? AppColors.signature : AppColors.muted)),
                ],
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Strict 3:4 product card: top 65% = flat-lay image on a light backing
/// (graceful placeholder), bottom 35% = brand caps / one-line title / price.
/// The whole card is the buy action; the bag glyph signals it.
class _ProductCard extends StatelessWidget {
  const _ProductCard(
      {required this.item, required this.onTap, required this.onBuy,
      required this.active, required this.flatLay});
  final Map<String, dynamic> item;
  final VoidCallback onTap; // select/preview in-app — never leaves the app
  final VoidCallback onBuy; // the explicit external shop action (bag icon)
  final bool active;
  // Lazily-started, session-cached Gemini product shot — used when the feed
  // carries no real photo. Calling it repeatedly returns the same future.
  final Future<Uint8List> Function() flatLay;

  /// Editorial brand tile — the LAST resort (feed photo missing AND the
  /// generated flat-lay failed). Oversized ghost letterform + brand caps so it
  /// still reads as designed, never as a broken blank card.
  Widget _brandTile() {
    final brand = (item['brand'] ?? '').toString().toUpperCase();
    return Container(
      color: const Color(0xFFF4F4F2),
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(),
      child: Stack(alignment: Alignment.center, children: [
        Positioned(
          right: -10, bottom: -26,
          child: Text(brand.isEmpty ? '?' : brand[0],
              style: TextStyle(
                  fontSize: 92, fontWeight: FontWeight.w900, height: 1,
                  color: AppColors.ink.withValues(alpha: 0.06))),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(brand.isEmpty ? '—' : brand,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.8,
                  color: AppColors.muted, height: 1.4)),
        ),
      ]),
    );
  }

  /// Generated product shot: shimmer while Gemini draws, ghost tile on failure.
  Widget _generatedShot() => FutureBuilder<Uint8List>(
        future: flatLay(),
        builder: (_, s) {
          if (s.hasData) {
            return Container(
              color: Colors.white,
              padding: const EdgeInsets.all(6),
              alignment: Alignment.center,
              child: Image.memory(s.data!,
                  fit: BoxFit.contain, width: double.infinity, gaplessPlayback: true),
            );
          }
          if (s.hasError) return _brandTile();
          return Stack(fit: StackFit.expand, alignment: Alignment.center, children: [
            const Shimmer(child: ShimmerBox(height: double.infinity, radius: 0)),
            Center(
              child: Text((item['brand'] ?? '').toString().toUpperCase(),
                  style: const TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w800,
                      letterSpacing: 1.8, color: AppColors.muted)),
            ),
          ]);
        },
      );

  @override
  Widget build(BuildContext context) {
    final raw = (item['imageUrl'] ?? '').toString();
    // placehold.co "text tiles" render as junk collages — treat them as
    // missing imagery and generate our own product shot instead.
    final img = raw.contains('placehold.co') ? '' : raw;
    return AspectRatio(
      aspectRatio: 3 / 4,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppRadius.control),
            border: Border.all(
                color: active ? AppColors.ink : AppColors.line, width: active ? 1.5 : 1),
            boxShadow: active
                ? const [BoxShadow(color: Color(0x1A000000), blurRadius: 12, offset: Offset(0, 4))]
                : const [],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // ── Image area: 58% ────────────────────────────────────────────
            Expanded(
              flex: 58,
              child: SizedBox(
                width: double.infinity,
                child: img.isEmpty
                    ? _generatedShot()
                    : Image.network(img,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _generatedShot()),
              ),
            ),
            // ── Text area: 42% — commerce-first ────────────────────────────
            Expanded(
              flex: 42,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(9, 6, 9, 7),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text((item['brand'] ?? '').toString().toUpperCase(),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.4,
                          color: AppColors.ink)),
                  const SizedBox(height: 1),
                  Text((item['name'] ?? '').toString(),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5, color: AppColors.inkSoft)),
                  const SizedBox(height: 2),
                  // Price in the accent color — the conversion cue.
                  Text('${item['currency'] ?? 'USD'} ${item['price'] ?? ''}',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.signature)),
                  const Spacer(),
                  // Primary, immediate purchase trigger (safe external launch).
                  SizedBox(
                    width: double.infinity, height: 26,
                    child: FilledButton(
                      onPressed: onBuy,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.ink,
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                      ),
                      child: const Text('Buy Now',
                          style: TextStyle(
                              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
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

class _Failed extends StatelessWidget {
  const _Failed({this.error, required this.onRetry});
  final Object? error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final quota = error is PaywallRequired;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(quota ? 'No looks left' : 'Couldn’t create those looks', style: AppType.h2),
          const SizedBox(height: 8),
          Text(
            quota
                ? 'You’ve used your free looks.'
                : 'Something went wrong. Your credit was not used for a failure.',
            style: const TextStyle(color: AppColors.muted, height: 1.4),
          ),
          const SizedBox(height: 20),
          if (!quota) FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}
