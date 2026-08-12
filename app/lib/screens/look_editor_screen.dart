import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'package:easy_localization/easy_localization.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/autocrop.dart';
import '../utils/webp_payload.dart';
import '../models/analysis.dart';
import '../models/subject.dart';
import '../flags.dart';
import '../providers.dart';
import '../services/analytics.dart';
import '../services/api_client.dart' show ApiException, PaywallRequired;
import '../services/native_looktok_engine.dart';
import '../state/outfit_state.dart';
import '../theme.dart';
import '../widgets/closet_badge.dart';
import '../widgets/progressive_garment_stream.dart';
import '../widgets/style_scanner.dart';
import '../widgets/subject_sheet.dart';
import 'paywall_screen.dart';

/// P0-1 — Sectioned avatar editor, the flagship surface. Slot-based editing on
/// the user's avatar: pick a slot (top/bottom/shoes/…), cycle alternatives —
/// each swap renders on the avatar in place. Alternatives are labeled
/// "Wardrobe" (their clothes) or "Idea" (styling idea). Slot lock via the lock
/// icon. Swaps are per-slot scoped edits — never a full-look regeneration.
/// Inspiration only, not products — no commerce anywhere on this surface.
class LookEditorScreen extends ConsumerStatefulWidget {
  const LookEditorScreen(
      {super.key,
      required this.imageBytes,
      this.cleanImageBytes,
      this.analysis,
      this.score,
      this.seedInstruction,
      this.seedLabel,
      this.subject = const Subject.me(),
      this.demoPickRecommended = false,
      this.onFullyReady,
      this.analysisFuture,
      this.cleanFuture});
  final Uint8List imageBytes;

  /// The ISOLATED transparent-PNG cutout from the processing pipeline, passed
  /// as a typed argument (never any UI capture). When present, the NOW avatar
  /// consumes exactly these bytes via Image.memory.
  final Uint8List? cleanImageBytes;
  final AnalysisResult? analysis; // seeds flagged slots + "why it's better" (Fit Check entry)

  /// INSTANT-ENTRY flow (owner constraint: no standalone checklist loaders):
  /// the critique resolves WHILE the user is already on this screen — the
  /// avatar carries the scanner overlay, the sheet a skeleton, until then.
  final Future<AnalysisResult>? analysisFuture;

  /// The pipeline's isolation result for the same instant-entry flow — reused
  /// so the editor never runs a duplicate on-device extraction.
  final Future<Uint8List?>? cleanFuture;
  final int? score;
  final String? seedInstruction; // single fix seed (rec-card entry)
  final String? seedLabel;
  final Subject subject; // whose look — tags the save with a guest name (§14.10)
  final bool demoPickRecommended; // marketing capture only: auto-apply the PICK on load

  /// Fires once, after the first frame in which the editor is fully rendered
  /// (slots detected + the NOW image resolved in memory) — or on a fatal load
  /// error. The caller uses it to drop the app-level loader overlay.
  final VoidCallback? onFullyReady;

  @override
  ConsumerState<LookEditorScreen> createState() => _LookEditorScreenState();
}

class _Alt {
  _Alt({required this.label, required this.source, required this.instruction, this.why, this.recommended = false, this.shop});
  final String label;
  final String source; // 'wardrobe' | 'idea'
  final String instruction;
  final String? why; // one-sentence rationale for "Why it's better"
  final bool recommended; // the stylist's top pick for this slot
  final Map<String, dynamic>? shop; // matched REAL SKU {brand, price, currency, buyUrl}
}

class _Slot {
  _Slot({required this.slot, required this.item, required this.alts});
  final String slot;
  final String item;
  final List<_Alt> alts;
}

// White studio backdrop — matches the render background so colours don't clash.
const _studioBg = Color(0xFFFFFFFF);

// Framing rule appended to every render: person fills the frame (no tiny avatar),
// even margins, on a clean pure-white backdrop.
const _framing =
    'Place the person centered and full-length, head-to-toe, filling the frame '
    'vertically so they take up almost the entire image height with only a thin, even '
    'margin on all sides. Use a plain seamless pure-white (#FFFFFF) studio background that '
    'fills the whole frame — no grey edges, no dark band, no vignette, no blur. '
    'No text, UI or watermarks.';

// Close-up framing for small accessories (watch/jewelry). A full-body frame
// leaves the wrist/neck ~30px — too few for a legible watch. A WAIST-UP crop
// roughly doubles the scale so the piece reads, while KEEPING THE FACE in
// frame (the server identity gate compares faces — a bare-wrist crop would
// have none). The feet guard is skipped for this framing (no feet expected).
const _closeUpFraming =
    'Compose a WAIST-UP portrait crop: camera moved closer so the frame runs '
    'from the top of the head to roughly the waist, keeping the face clearly in '
    'frame. The accessory being added MUST be rendered LARGE, sharp and clearly '
    'visible at this closer distance. Plain seamless pure-white (#FFFFFF) studio '
    'background filling the frame — no grey edges, no vignette, no blur. '
    'No text, UI or watermarks.';

/// True if two garment descriptions are effectively the same (used to drop an
/// "idea" that just repeats what the person already wears, or another idea).
bool _dupGarment(String a, String b) {
  String n(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final x = n(a), y = n(b);
  if (x.isEmpty || y.isEmpty) return false;
  if (x == y || x.contains(y) || y.contains(x)) return true;
  final xs = x.split(' ').toSet(), ys = y.split(' ').toSet();
  final inter = xs.intersection(ys).length;
  final minLen = xs.length < ys.length ? xs.length : ys.length;
  return minLen > 0 && inter / minLen >= 0.8; // ~same words → treat as duplicate
}

const _slotToCategory = {
  'top': 'top', 'bottom': 'bottom', 'outerwear': 'outerwear', 'shoes': 'shoes',
  'belt': 'accessory', 'accessories': 'accessory', 'bag': 'accessory',
};

class _LookEditorScreenState extends ConsumerState<LookEditorScreen> {
  late Uint8List _base = widget.imageBytes; // ORIGINAL photo — never mutated
  /// Storage path of the most recent server render, when there is one. The
  /// first swap of a session still ships pixels (the source photo is only on
  /// the device); every swap after it sends this path instead — ~2s of mobile
  /// uplink and ~1s of server restaging per tap.
  // Kept for My Looks (what the last render was), NOT for chaining: rendering a
  // swap on top of a previous render is what made artefacts compound. See the note
  // at the `personPath: null` call below.
  String? _lastRenderPath;
  String? _baseB64; // memo of base64(_base)
  List<_Slot>? _slots;
  String? _error;
  int _sel = 0; // selected slot
  int _alt = 0; // 0 = no pick for this slot, 1.. = alternatives
  final Set<int> _locked = {}; // slots "kept" as-is (Style-my-look won't touch)
  // Renders are cached by the SET of swaps applied, composed off the ORIGINAL —
  // so wearing (which just adds to _picked, an already-shown set) never
  // re-renders, and revisiting any combination is instant.
  final Map<String, Future<Uint8List>> _cache = {};
  bool _saving = false;
  bool _sheetOpen = true; // bottom controls expanded; can collapse for a full-screen photo
  bool _noteExpanded = false; // tap the stylist note to show it in full
  AnalysisResult? _analysis; // widget.analysis, or the late analysisFuture result
  final Map<int, int> _picked = {}; // slotIdx → worn altIdx (persists across slots)
  final Set<int> _flagged = {}; // slots the review flagged as needing a change
  // Item-only thumbnails (just the garment on white, NO person) — cheap to
  // generate; the expensive on-body render happens only when the user picks one.
  final Map<String, Future<Uint8List>> _items = {};
  // Sync mirror of finished thumbnails: freshly-mounted FutureBuilders spend a
  // frame in "waiting" even on completed futures — that flash was the perceived
  // "reload" when switching category tabs. Bytes here render instantly.
  final Map<String, Uint8List> _itemBytesSync = {};
  String? _whiteBase;
  Uint8List? _lastShown; // last successfully displayed render — optimistic backdrop while the next bakes
  // Session cache, sync tier: completed on-body renders by combo key. A cache
  // hit paints the avatar synchronously — no loader, no API, not even a frame.
  final Map<String, Uint8List> _renderBytesSync = {};
  // On-body renders currently in flight, by combo key — drives the avatar
  // shimmer and each card's micro-progress strip (works for user taps AND
  // background prefetch alike, since both funnel through _renderSet).
  final Set<String> _rendering = {};
  // Latent streaming: the fix_renders id whose TAESD previews are currently
  // crystallizing over the avatar. Null when nothing is in flight — the widget
  // it feeds is garnish over the normal polling path, never a gate.
  String? _streamRenderId;
  String? _guestName; // captured once on save for a guest (§14.10)
  final TransformationController _zoom = TransformationController();

  // Single source of truth for the main avatar image; every selection change
  // reassigns it inside setState → the avatar re-renders, guaranteed (Bug 1).
  Future<Uint8List>? _avatarFut;
  void _syncAvatar() => _avatarFut = _renderSet(_effective);

  String get _b64 => _baseB64 ??= base64Encode(_base);

  /// Telegram-style downscale + JPEG compress — smaller payloads render faster.
  Future<Uint8List> _shrink(Uint8List bytes) async {
    try {
      final out = await FlutterImageCompress.compressWithList(bytes,
          minWidth: 800, minHeight: 800, quality: 70, format: CompressFormat.jpeg);
      return out.isNotEmpty ? out : bytes;
    } catch (_) {
      return bytes;
    }
  }

  // SINGLE SOURCE OF TRUTH for the person sprite: the ISOLATED transparent
  // cutout. Comes from the pipeline (typed argument) or is extracted on-device
  // right here. The raw camera asset must never reach a loading/preview
  // surface — it exists only as generation INPUT (_base) for Gemini.
  Uint8List? _cleanBase;
  // Resolves exactly once: the pipeline cutout, or an on-device extraction for
  // entry paths without one. NOW *awaits* this — it never races it.
  late final Future<Uint8List?> _cleanFut;

  @override
  void initState() {
    super.initState();
    _analysis = widget.analysis;
    _cleanBase = widget.cleanImageBytes;
    _cleanFut = _cleanBase != null
        ? Future.value(_cleanBase)
        : (widget.cleanFuture != null
            // The pipeline is already isolating this exact photo — never run a
            // duplicate extraction; fall back only if the pipeline yields null.
            ? widget.cleanFuture!
                .catchError((_) => null)
                .then((b) async =>
                    b ?? await NativeLooktokEngine.instance.extractSilhouette(_base))
            : NativeLooktokEngine.instance.extractSilhouette(_base));
    if (_cleanBase == null) {
      _cleanFut.then((b) {
        if (b == null || !mounted) return;
        setState(() {
          _cleanBase = b;
          _itemBytesSync['~now'] = b; // NOW thumb flips to the sprite too
        });
      });
    }
    // NOTE: no eager neutral-base warm here anymore — top swaps now render in
    // ONE pass grounded by the garment's flat-lay reference, using the base
    // only as a rare fallback (no-reference ideas). Warming it eagerly would
    // burn a render that's usually never used.
    _load();
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final api = ref.read(looktokApiProvider);
      // Compress the incoming photo first — every downstream render is faster.
      _base = await _shrink(widget.imageBytes);
      _baseB64 = null;
      final origB64 = _b64;
      // No separate normalization pass: every render (NOW + each alternative)
      // normalizes the background itself in one call, off the original — so the
      // slow normalize→then→render chain is gone and everything runs in parallel.
      final slotsFut = api.outfitSlots(origB64, 'image/jpeg');
      if (widget.analysisFuture != null) {
        // Instant entry: the critique lands while the scanner runs on the
        // avatar. An unusable photo/quota ends THIS screen's error state —
        // there is no upstream loader to fall back to.
        try {
          _analysis = await widget.analysisFuture;
        } on PaywallRequired {
          if (mounted) setState(() => _error = 'No reads left — upgrade to keep styling.');
          widget.onFullyReady?.call();
          return;
        }
        if (!(_analysis?.analyzable ?? true)) {
          if (mounted) {
            setState(() => _error = _analysis?.note ??
                'That photo can’t be analyzed. Try a clear, full-body shot.');
          }
          widget.onFullyReady?.call();
          return;
        }
      }
      final detected = await slotsFut;
      _gender = detected.gender;
      final raw = detected.slots;
      // A guest's review must not offer MY closet — those are the owner's
      // clothes, not theirs. Ideas only.
      final wardrobe = widget.subject.isGuest
          ? const <Map<String, dynamic>>[]
          : await api.wardrobeItems();

      final slots = <_Slot>[];
      for (final s in raw) {
        final slot = (s['slot'] ?? '').toString();
        final item = (s['item'] ?? '').toString();
        final alts = <_Alt>[];
        // Wardrobe first — their actual clothes for this slot (max 2).
        // EFFECTIVE category: the label's own keywords override a bad DB row
        // ("navy shorts" stored as top must never surface in the Top tab).
        final cat = _slotToCategory[slot];
        bool belongsHere(Map<String, dynamic> w) {
          final label = (w['label'] ?? '').toString();
          final derived = _categoryFromLabel(label);
          return (derived ?? w['category']) == cat;
        }
        for (final w in wardrobe.where(belongsHere).take(2)) {
          final label = (w['label'] ?? 'Your piece').toString();
          // SHORTS ARE OFF THE MENU until the render base has bare legs — the
          // engine measurably cannot render them (long navy trousers, a white
          // fill band, denim tubes around the pocketed hands). The catalogue is
          // already vetoed server-side in outfit-slots, but wardrobe items enter
          // the rail HERE, client-side, and bypassed that veto: the user's own
          // "navy shorts" kept reappearing after the server was clean, which
          // cost an evening of chasing phantom cache. Same gate, same reason;
          // lift both together with the minimal-base work.
          if (RegExp(r'shorts|шорт', caseSensitive: false).hasMatch(label)) {
            continue;
          }
          alts.add(_Alt(label: label, source: 'wardrobe', instruction: 'their own $label', why: 'A piece you already own that fits this look.'));
        }
        // Styling ideas (each carries its own "why it's better") — 4 per slot.
        for (final idea in ((s['ideas'] as List?) ?? const []).take(4)) {
          final m = (idea as Map).cast<String, dynamic>();
          final g = (m['garment'] ?? '').toString();
          if (g.isEmpty) continue;
          if (_dupGarment(g, item)) continue; // don't repeat what they wear now
          if (alts.any((a) => _dupGarment(g, a.label))) continue; // no near-duplicate ideas
          final shop = m['shop'] is Map ? (m['shop'] as Map).cast<String, dynamic>() : null;
          // LIBRARY: a matched generated flat-lay → its image IS the thumbnail
          // (instant, no per-item Gemini render) and the render reference.
          final libUrl = shop?['imageUrl']?.toString();
          if (libUrl != null && libUrl.isNotEmpty) _libImg[g] = libUrl;
          alts.add(_Alt(
              label: g, source: 'idea', instruction: g,
              why: m['why']?.toString(), recommended: m['recommended'] == true,
              shop: shop));
        }
        // Surface the stylist's recommended pick(s) first (stable order otherwise).
        final ordered = [...alts.where((a) => a.recommended), ...alts.where((a) => !a.recommended)];
        if (ordered.isNotEmpty) slots.add(_Slot(slot: slot, item: item, alts: ordered.take(4).toList()));
      }
      // Merge repeated slots (e.g. detection returning 'accessories' several
      // times for watch/glasses/cap) so the rail never shows a tab twice.
      final merged = <String, _Slot>{};
      for (final s in slots) {
        final ex = merged[s.slot];
        if (ex == null) {
          merged[s.slot] = s;
        } else {
          for (final a in s.alts) {
            if (!ex.alts.any((x) => _dupGarment(a.label, x.label))) ex.alts.add(a);
          }
        }
      }
      slots
        ..clear()
        ..addAll(merged.values);
      for (final s in slots) {
        if (s.alts.length > 4) s.alts.removeRange(4, s.alts.length);
      }
      if (slots.isEmpty) throw Exception('no slots');

      var focus = 0;
      // Fit Check entry: seed flagged slots from the analysis; "why" = the problem.
      if (_analysis != null) {
        var first = true;
        for (final h in _analysis!.hotspots.where((h) => h.severity != 'good')) {
          final si = _guessSlot(slots, '${h.area} ${h.title} ${h.fix ?? ''}');
          slots[si].alts.insert(0, _Alt(label: h.title, source: 'idea', instruction: h.fix ?? h.title, why: h.detail));
          _flagged.add(si); // this slot needs a change → drives "Style the best look"
          if (first) { focus = si; first = false; }
        }
      } else if (widget.seedInstruction != null) {
        // Rec-card entry: a single fix.
        focus = _guessSlot(slots, widget.seedInstruction!);
        slots[focus].alts.insert(0,
            _Alt(label: widget.seedLabel ?? 'The fix', source: 'idea', instruction: widget.seedInstruction!, why: widget.seedLabel));
      }
      // Final order per slot: the stylist's recommended PICK always first (with
      // its star), then everything else in place, capped at 4.
      for (final s in slots) {
        final rec = s.alts.where((a) => a.recommended).toList();
        final rest = s.alts.where((a) => !a.recommended).toList();
        final merged = [...rec, ...rest];
        s.alts
          ..clear()
          ..addAll(merged.take(4));
      }
      // Always open on the Top category (fall back to the flagged slot only if
      // there's no top). `focus` still drives flagged-slot pre-warming below.
      final topIdx = slots.indexWhere((s) => s.slot == 'top');
      setState(() {
        _slots = slots;
        // Grid-batch the unmatched idea thumbnails (fire-and-forget: the lazy
        // per-item FutureBuilders cover anything the batch misses).
        unawaited(_batchThumbs(slots));
        if (_kLooksFirst) {
          _lookBoardsPending = true;
          unawaited(_loadLookBoards(slots).catchError((_) {
            if (mounted) setState(() => _lookBoardsPending = false);
          }));
        }
        _sel = topIdx >= 0 ? topIdx : focus;
        // Entry state is ALWAYS the user's own look: no preview (_alt = 0) and
        // no worn picks — every category defaults to NOW until they tap.
        _alt = 0;
        _picked.clear();
      });
      // COST: reveal on NOW + the OPENING slot's thumbnails only. Other slots'
      // thumbs lazy-load when their category is opened (each _thumb's
      // FutureBuilder starts _itemImage on demand, cached by description) —
      // was: every thumb of every slot upfront (~16 image calls per open).
      final openSlot = slots.indexWhere((s) => s.slot == 'top') >= 0
          ? slots[slots.indexWhere((s) => s.slot == 'top')]
          : slots[focus];
      // FAST REVEAL: the NOW frame is the user's own photo (instant, no Gemini),
      // and every thumbnail has a shimmer/spinner placeholder + sync cache — so
      // there is nothing worth blocking on. Waiting for the opening slot's
      // Gemini thumbnails here was the 15–40s "Styling your look" wall.
      // Kick the opening slot's thumbnails (background) and reveal immediately.
      for (final alt in openSlot.alts) {
        _itemImage(alt.instruction, openSlot.slot)
            .then((b) => _itemBytesSync[alt.instruction] ??= b, onError: (_) {});
      }
      await _renderSet(const {}).catchError((_) => _base); // ~instant: crop of the original
      if (mounted) setState(() {}); // slots + critique landed → sheet gets real content
      // Fully rendered + NOW image in memory → the app-level overlay may drop.
      // Post-frame: the signal fires only after this state actually painted.
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onFullyReady?.call());
      // Marketing capture: auto-apply the stylist's PICK for the focused slot so
      // the "restyle" shot shows a swapped piece on the avatar (already rendered
      // above, so the swap is instant). Not part of any user flow.
      if (widget.demoPickRecommended && mounted) {
        final alts = slots[focus].alts;
        final ri = alts.indexWhere((a) => a.recommended);
        _pickAlt(ri >= 0 ? ri + 1 : (alts.isNotEmpty ? 1 : 0));
      }
      // Smart Prefetch Queue: warm the focused slot's Top Pick first, then a
      // low-priority background queue walks the REMAINING categories' PICKs
      // (one call in flight; never IDEA/YOURS). Tab taps jump the queue.
      // COLLAGE MODE: no render prefetch at all — browsing is the free paper-
      // doll board; the only renders are explicit "Dress me in this" taps.
      final ri = slots[focus].alts.indexWhere((a) => a.recommended);
      if (!_kCollagePreview && ri >= 0) _renderSet({focus: ri + 1});
      // NOTE: neutral bases are no longer warmed eagerly here. The hybrid
      // render paints Phase 1 on the clean photo (no base needed), and Phase 2
      // (_upgradeToBase) lazily warms the right base on the first top/bottom
      // swap. Warming both bases on entry stacked 2 extra renders onto the
      // initial burst (prefetch + thumbs) and spiked Gemini into empty "no
      // image" responses — lazy warming keeps the entry light.
      if (!_kCollagePreview) _startPrefetchQueue();
      // Warm every category's item thumbnails in the background. THREE in
      // flight (was strictly sequential: 16 thumbs × ~6s ≈ 90s — far tabs
      // still showed spinners a minute in). Same total cost, ~3× sooner ready;
      // tapping a tab jumps its thumbs to the queue front.
      _startThumbWarm(slots);
    } catch (e) {
      // Carry the REAL reason. The blanket "couldn't read this look" hid a dead
      // session for a whole session of debugging (01.08): every call was 401'ing
      // and the screen still blamed the photo. Transport errors already ship
      // user-ready copy; only unknown ones fall back to the generic line.
      final why = e is ApiException ? e.message : null;
      if (mounted) {
        setState(() => _error = why ?? 'Couldn’t read this look. Try again.');
      }
      widget.onFullyReady?.call(); // error state is "ready" too — never wedge the overlay
    }
  }

  // Garment-type keywords per category — drives slot guessing AND the strict
  // single-item constraint on the alternatives rail.
  static const _slotHints = {
    'belt': ['belt'],
    'shoes': ['shoe', 'sneaker', 'boot', 'loafer', 'sandal', 'footwear', 'heel'],
    'bottom': ['pant', 'trouser', 'jean', 'chino', 'skirt', 'short', 'hem', 'break'],
    'outerwear': ['jacket', 'coat', 'blazer', 'overshirt', 'cardigan', 'layer'],
    'bag': ['bag', 'tote', 'backpack'],
    // Premium accessory studio: dedicated slots, each strictly its own kind.
    'glasses': ['glasses', 'sunglasses', 'eyewear', 'frames', 'aviator'],
    'watch': ['watch', 'chronograph', 'timepiece', 'strap', 'bracelet watch'],
    'jewelry': ['necklace', 'chain', 'pendant', 'bracelet', 'ring', 'earring', 'jewel'],
    'accessories': ['watch', 'scarf', 'hat', 'jewel', 'accessor', 'glasses'],
    'top': ['shirt', 'tee', 't-shirt', 'sweater', 'knit', 'polo', 'collar', 'sleeve', 'top'],
  };

  /// STRICT category constraint: true when [desc] reads as ONE item of [slot].
  /// An alt whose text spans 2+ FOREIGN garment categories is an outfit-set
  /// description — its product shot renders as a 4-item collage, which must
  /// never appear inside a single-category tab. (One foreign mention is fine:
  /// "polo to pair with chinos" is styling context, not a set.)
  bool _isSingleCategoryItem(String desc, String slot) {
    final t = desc.toLowerCase();
    var foreign = 0;
    for (final e in _slotHints.entries) {
      if (e.key == slot) continue;
      if (e.value.any(t.contains)) foreign++;
    }
    return foreign < 2;
  }

  /// 1-based alt indices of the ACTIVE slot that pass the single-item rule.
  List<int> _visibleAlts() => [
        for (var i = 0; i < _slots![_sel].alts.length; i++)
          if (_isSingleCategoryItem(_slots![_sel].alts[i].instruction, _slots![_sel].slot)) i + 1,
      ];

  /// Category a garment LABEL clearly describes ('navy shorts' → bottom), or
  /// null when the words don't pin one down. Order matters: specific garment
  /// words (shorts/sneakers) are checked before the greedy 'top' bucket.
  static String? _categoryFromLabel(String label) {
    final t = label.toLowerCase();
    for (final slot in const ['shoes', 'bottom', 'outerwear', 'belt', 'bag', 'accessories', 'top']) {
      if ((_slotHints[slot] ?? const []).any(t.contains)) return _slotToCategory[slot];
    }
    return null;
  }

  int _guessSlot(List<_Slot> slots, String text) {
    final t = text.toLowerCase();
    for (final e in _slotHints.entries) {
      if (e.value.any(t.contains)) {
        final i = slots.indexWhere((s) => s.slot == e.key);
        if (i >= 0) return i;
      }
    }
    return 0;
  }

  /// One VTON call + best-effort crop. Resilience (45s per-attempt timeout,
  /// exponential-backoff retries on transient 5xx/timeouts/dead sockets) lives
  /// in the API layer now — a retry loop HERE would multiply into up to 6 paid
  /// image generations per flake. Exhausted retries surface as a clean
  /// ApiException that the avatar's error state displays verbatim.
  // Combos whose visible render is being silently REFINED by the worker (QA
  // failed v1; v2 in flight) — drives the "Perfecting…" badge on the avatar.
  final Set<String> _refining = {};

  // Tucked twins IN FLIGHT, keyed by the twin's combo key: tapping "Tucked"
  // while the worker is still producing the twin WAITS for it instead of
  // dispatching a duplicate from-scratch render (which could drift the item).
  final Map<String, Future<Uint8List>> _twinFutures = {};

  // The render's PERSON input, memoized: the isolated cutout (webp). Feeding
  // the raw camera photo let renders keep the fitting-room scene and anchor on
  // the original garment's cut — the cutout carries neither.
  Uint8List? _cleanPayload;
  String? _cleanPayloadB64;

  // ── NEUTRAL MANNEQUIN BASE (cut-inheritance kill switch) ─────────────────
  // Prompts alone kept losing to the source pixels: a striped tee landed
  // SLEEVELESS because the model anchored on the sleeveless top it SAW. So
  // top swaps no longer see it: ONE cached render puts the person in a plain
  // grey crew-neck tee, and every top swap renders FROM that base — the
  // original cut simply isn't in the input anymore.
  static const _kNeutralInstr =
      'MANDATORY EDIT: take OFF the current top and dress them in a plain '
      'fitted heather-grey SHORT-SLEEVE crew-neck t-shirt — short set-in '
      'sleeves clearly covering the shoulders and the upper arms, hem worn '
      'loose over the bottoms. This is a neutral fitting-mannequin base: no '
      'prints, no logos, no pockets.';
  // NOTE: a symmetric BOTTOM base was tried and REVERTED — dressing new shorts
  // onto a full-length trouser base made flash-image LAYER them (shorts over
  // trousers, a visible "double bottom"). Bottoms rely on Phase-1 + the
  // leg-length prompt clause instead; only TOP swaps get the Phase-2 upgrade.
  Future<Uint8List>? _neutralFut;
  Uint8List? _neutralBase;
  final Map<int, String> _basePayloadB64 = {}; // base identity → tryon payload b64
  Future<String?>? _identityFut; // b64 head crop — the face identity anchor

  /// The person in the neutral grey tee (cached per photo; server+disk cache
  /// make this a one-time cost). Kicked off in the background as soon as the
  /// slots arrive, awaited only by top swaps.
  /// Deterministic feet check (bottom-band pixel test). True = the figure is
  /// cropped. Fails safe: any decode error reads as "not cropped".
  Future<bool> _feetCropped(Uint8List bytes) async {
    try {
      return await compute(feetCutOff, bytes);
    } catch (_) {
      return false;
    }
  }

  /// Escalation suffix for a feet re-order. The millisecond nonce makes every
  /// retake a UNIQUE cache fingerprint — a cropped render that slipped into
  /// the server cache can never echo back as its own "fix".
  String _retakeNote(int attempt) =>
      ' RETAKE #$attempt [${DateTime.now().millisecondsSinceEpoch}]: the '
      'previous output CROPPED the person. Render the FULL BODY head-to-toe — '
      'feet and shoes fully visible with clear white margin below the shoes. '
      'A frame that cuts the person at the knees or ankles is a FAILED '
      'generation.';

  // FIXED locked zones for the neutral base — NOT derived from detected slots.
  // The base's cache fingerprint includes its zones; if they varied per photo's
  // detection the base was re-rendered every time. Constant zones = one stable
  // key per clean photo → the server tryon_cache is reused across sessions AND
  // between Review and Generate, so the base render leaves the swap critical
  // path after the very first time. (Bottom/shoes/accessories are preserved;
  // the base only ever changes the top.)
  static const _kNeutralLocked = ['bottom', 'shoes', 'accessories'];

  Future<Uint8List> _ensureNeutralBase() {
    return _neutralFut ??= () async {
      try {
        var bytes = await _gen(_kNeutralInstr,
            targetZones: const ['top'], lockedZones: _kNeutralLocked, comboKey: '~neutral');
        // A cropped BASE would propagate the crop into every top swap built
        // on it — one strict re-order, then give up to the classic path.
        if (await _feetCropped(bytes)) {
          bytes = await _gen('$_kNeutralInstr${_retakeNote(1)}',
              targetZones: const ['top'],
              lockedZones: _kNeutralLocked,
              comboKey: '~neutral');
          if (await _feetCropped(bytes)) {
            throw ApiException('neutral base cropped twice');
          }
        }
        _neutralBase = bytes;
        return bytes;
      } catch (e) {
        _neutralFut = null; // transient failure → retry on next top swap
        rethrow;
      }
    }();
  }

  Future<Uint8List> _gen(String instruction,
      {List<String> targetZones = const [],
      List<String> lockedZones = const [],
      List<Uint8List> references = const [],
      List<String> referenceUrls = const [],
      List<String> referenceZones = const [],
      List<String> referenceHints = const [],
      String? personPath,
      String? comboKey,
      ({String instruction, List<String> targetZones, List<String> lockedZones})? tucked,
      String? tuckedKey,
      Uint8List? personOverride}) async {
    final api = ref.read(looktokApiProvider);
    String b64 = _b64;
    String mime = 'image/jpeg';
    try {
      if (personOverride != null) {
        // NEUTRAL-BASE path: the input photo is the mannequin render — the
        // source garment's cut is physically absent from the pixels. Keyed by
        // the base object's identity so the TOP base and the BOTTOM base never
        // share one cached payload (they are distinct renders).
        final k = identityHashCode(personOverride);
        b64 = _basePayloadB64[k] ??= base64Encode(await toTryonPayload(personOverride));
        mime = 'image/png';
      } else {
        final clean = _cleanBase ?? await _cleanFut;
        if (clean != null) {
          _cleanPayload ??= await toTryonPayload(clean);
          _cleanPayloadB64 ??= base64Encode(_cleanPayload!);
          b64 = _cleanPayloadB64!;
          mime = imageMime(_cleanPayload!);
        }
      }
    } catch (_) {/* raw fallback */}
    // Face anchor: cropped once per photo, attached to EVERY dispatch. The
    // pre-paint identity gate compares against this crop server-side.
    String? identityB64;
    try {
      _identityFut ??= () async {
        final src = _cleanBase ?? await _cleanFut ?? widget.imageBytes;
        return base64Encode(await compute(headCrop, src));
      }();
      identityB64 = await _identityFut!.timeout(const Duration(seconds: 4));
    } catch (_) {/* anchor is best-effort */}
    final tier =
        (ref.read(entitlementProvider).valueOrNull?['pro'] == true) ? 'pro' : 'free';
    Analytics.generationStarted(tier: tier);
    final genT0 = DateTime.now();
    // REALTIME SWAP ("fast first, right after"): dispatch answers in <1s with
    // either cached bytes or a fix_renders row id. The row streams v1 the
    // moment it renders (the future completes → avatar paints), then a
    // QA-refined v2 silently REPLACES it in place via the combo caches — the
    // user no longer waits out the verify+retry before seeing anything.
    final d = await api.dispatchFix(
        base64Image: b64,
        mimeType: mime,
        instruction: instruction,
        targetZones: targetZones,
        lockedZones: lockedZones,
        references: references,
        referenceUrls: referenceUrls,
        referenceZones: referenceZones,
        referenceHints: referenceHints,
        personPath: personPath,
        tucked: tucked,
        identityB64: identityB64);
    Completer<Uint8List>? twinC;
    if (tuckedKey != null) {
      twinC = Completer<Uint8List>();
      _twinFutures[tuckedKey] = twinC.future;
      twinC.future.then((_) {}, onError: (_) {}); // never an unhandled error
    }
    void twinDone() {
      if (twinC != null && !twinC.isCompleted) {
        twinC.completeError(ApiException('twin not produced'));
      }
      if (tuckedKey != null) _twinFutures.remove(tuckedKey);
    }

    Future<void> stashTucked(Uint8List raw) async {
      if (tuckedKey == null) return;
      Uint8List bytes;
      try {
        bytes = await compute(autoCropSubject, raw);
      } catch (_) {
        bytes = raw;
      }
      // Twin bypasses _renderSet's feet guard — never stash a cropped twin;
      // the toggle then renders its state on demand through the guarded path.
      if (await _feetCropped(bytes)) {
        twinDone();
        return;
      }
      _renderBytesSync[tuckedKey] = bytes;
      _cache[tuckedKey] = Future.value(bytes);
      if (twinC != null && !twinC.isCompleted) twinC.complete(bytes);
      _twinFutures.remove(tuckedKey);
      if (mounted) setState(() {});
    }

    if (d.bytes != null) {
      Analytics.generationCompleted(
          latencyMs: DateTime.now().difference(genT0).inMilliseconds);
      if (d.bytesTucked != null) {
        await stashTucked(d.bytesTucked!);
      } else {
        twinDone();
      }
      try {
        return await compute(autoCropSubject, d.bytes!);
      } catch (_) {
        return d.bytes!;
      }
    }
    final completer = Completer<Uint8List>();
    StreamSubscription<Map<String, dynamic>>? sub;
    Timer? guard;
    void finish() {
      guard?.cancel();
      sub?.cancel();
      if (mounted && _streamRenderId == d.renderId) {
        setState(() => _streamRenderId = null);
      }
    }

    // Zombie protection: a dead worker leaves the row pending forever — the
    // future must still fail into the avatar's tap-to-retry state.
    guard = Timer(const Duration(seconds: 100), () {
      finish();
      twinDone();
      if (!completer.isCompleted) {
        completer.completeError(
            ApiException('The render is taking too long — tap to retry.'));
      }
    });
    String? paintedPath;
    String? paintedTuckedPath;
    if (mounted) setState(() => _streamRenderId = d.renderId);
    sub = api.fixRender(d.renderId!).listen((row) async {
      if (row.isEmpty) return;
      final status = (row['status'] ?? '').toString();
      final phase = (row['phase'] ?? '').toString();
      final path = (row['image_path'] ?? '').toString();
      // Keep it: the NEXT swap sends this pointer instead of re-uploading the
      // look it is about to modify. The server signs it in place.
      if (path.isNotEmpty) _lastRenderPath = path;
      // The tucked twin lands on the SAME row — cache it the moment it
      // appears, so the toggle is a 0ms local source swap afterwards.
      final tPath = (row['image_path_tucked'] ?? '').toString();
      if (tPath.isNotEmpty && tPath != paintedTuckedPath) {
        paintedTuckedPath = tPath;
        try {
          await stashTucked(await _fetchRender(tPath));
        } catch (_) {/* twin is best-effort */}
      }
      if (status == 'failed') {
        finish();
        twinDone();
        if (comboKey != null && _refining.remove(comboKey) && mounted) {
          setState(() {});
        }
        if (!completer.isCompleted) {
          completer.completeError(ApiException(
              (row['error'] ?? 'Couldn’t render this look.').toString()));
        }
        return;
      }
      // Surface the silent QA replacement honestly: while phase == refining,
      // the avatar carries a small "Perfecting…" badge (a no-op v1 — tuck is
      // the usual case — otherwise reads as "не сработало").
      if (comboKey != null && mounted) {
        final refining = phase == 'refining';
        final changed =
            refining ? _refining.add(comboKey) : _refining.remove(comboKey);
        if (changed && mounted) setState(() {});
      }
      if (path.isNotEmpty && path != paintedPath) {
        paintedPath = path;
        try {
          final raw = await _fetchRender(path);
          Uint8List bytes;
          try {
            bytes = await compute(autoCropSubject, raw);
          } catch (_) {
            bytes = raw;
          }
          if (!completer.isCompleted) {
            Analytics.generationCompleted(
                latencyMs: DateTime.now().difference(genT0).inMilliseconds);
            completer.complete(bytes); // v1 — first paint
          } else if (comboKey != null && mounted) {
            // v2 — the silent QA replacement, same combo key, in place.
            // It bypasses _renderSet's feet guard, so check here: NEVER swap
            // a good painted frame for a cropped "refinement".
            if (!await _feetCropped(bytes)) {
              _renderBytesSync[comboKey] = bytes;
              _cache[comboKey] = Future.value(bytes);
              setState(() {});
            }
          }
        } catch (_) {/* keep whatever is painted; guard covers total silence */}
      }
      if (phase == 'done') {
        finish();
        twinDone();
      }
    }, onError: (_) {/* realtime hiccup — the guard timer covers it */});
    return completer.future;
  }

  /// Download a render object from the private generations bucket.
  Future<Uint8List> _fetchRender(String path) async {
    final url = await ref.read(looktokApiProvider).lookImageUrl(path);
    final res = await http.get(Uri.parse(url));
    if (res.statusCode != 200) throw ApiException('render fetch ${res.statusCode}');
    return res.bodyBytes;
  }

  // The swaps currently shown = worn picks, with the active slot overridden by
  // the live preview (_alt). alt 0 = no swap for that slot.
  Map<int, int> get _effective {
    final m = Map<int, int>.from(_picked);
    if (_alt > 0) {
      m[_sel] = _alt;
    } else {
      m.remove(_sel);
    }
    return m;
  }

  /// Deterministic garment-TYPE reinforcement appended to the edit line —
  /// prompts alone kept letting the model render trousers for "denim shorts".
  /// Same veto vocabulary as the RAG type guard and the thumbnail prompt.
  static String _typeMandate(String desc) {
    final t = desc.toLowerCase();
    if (RegExp(r'shorts?').hasMatch(t)) {
      return ' (this is SHORTS — the hem MUST end above the knee; rendering '
          'full-length trousers instead is a failed generation)';
    }
    if (RegExp(r'(trousers|pants|jeans|chinos|joggers)').hasMatch(t)) {
      return ' (full-length legwear reaching the ankle — never shorts)';
    }
    if (RegExp(r'skirt').hasMatch(t)) return ' (a skirt — not shorts, not trousers)';
    if (RegExp(r'sleeveless|tank').hasMatch(t)) return ' (sleeveless — no sleeves at all)';
    if (RegExp(r'long[- ]sleeve').hasMatch(t)) return ' (LONG sleeves to the wrist)';
    if (RegExp(r'short[- ]sleeve').hasMatch(t)) return ' (SHORT sleeves above the elbow)';
    // Construction mandates by garment NOUN — without these, a "hoodie" or
    // "t-shirt" swap inherited the ORIGINAL top's cut (a sleeveless muscle
    // tee stayed sleeveless, just recolored).
    if (RegExp(r'hoodie').hasMatch(t)) {
      return ' (a HOODIE — a hood and LONG sleeves to the wrist; never a '
          't-shirt or vest)';
    }
    if (RegExp(r'sweatshirt|sweater|jumper|pullover|cardigan').hasMatch(t)) {
      return ' (LONG sleeves to the wrist)';
    }
    if (RegExp(r'polo').hasMatch(t)) {
      return ' (a POLO — collar, buttoned placket, SHORT set-in sleeves '
          'covering the shoulders)';
    }
    if (RegExp(r't-?shirt|\btee\b').hasMatch(t)) {
      return ' (a T-SHIRT with SHORT set-in sleeves covering the shoulders '
          '— never sleeveless)';
    }
    return '';
  }

  // Gender presentation from slot detection — every thumb and render carries
  // it so ideas can never drift into womenswear on a masculine avatar (or
  // vice versa). 'neutral' adds nothing.
  String _gender = 'neutral';
  String get _genderNote => switch (_gender) {
        'masculine' =>
          ' STRICTLY MENSWEAR: never heels, heeled sandals, pumps, dresses, skirts, blouses or any womenswear.',
        'feminine' =>
          ' STRICTLY WOMENSWEAR, consistent with her presentation in the photo.',
        _ => '',
      };

  // FIT CONTROLS: how the clothes SIT (tuck, sleeves, outer layer) — each a
  // first-class, cache-keyed render dimension; toggling re-renders the set.
  /// The Premium ($19.99/mo) bundle. Visible in dev builds for founder
  /// testing; when RevenueCat lands, gate this panel on plan == 'premium'
  /// instead of the const. Turning it off re-parks the panel, the dual-tuck
  /// twin renders and the tuck prefetch — plumbing stays live underneath.
  static const bool _kFitControls = true;

  /// Premium entitlement RIGHT NOW (logic paths: dual-tuck twin, prefetch).
  /// The panel itself watches the provider so a purchase unlocks it live.
  bool get _premiumNow =>
      ref.read(entitlementProvider).valueOrNull?['premium'] == true;

  int _tuck = 0;
  int _sleeves = 0; // 0 natural · 1 rolled up
  int _layer = 0; // 0 natural · 1 outer layer worn open

  /// True when the entire change is small accessories (watch/jewelry) that
  /// need a waist-up close-up to be legible. Glasses are excluded — they read
  /// fine on the face at full-body scale. Empty set (NOW) is never close-up.
  bool _isCloseUpSet(Map<int, int> sel) =>
      sel.isNotEmpty &&
      sel.keys.every((k) {
        final s = _slots![k].slot;
        return s == 'watch' || s == 'jewelry';
      });

  /// Anatomical anchor for small accessories — tells the model WHERE the
  /// piece sits and to render it clearly (a bare slot name like "watch" gave
  /// the model no target). Garments return '' (their zone is obvious).
  String _anatomy(String slot) => switch (slot) {
        'glasses' => ', worn on the face over the eyes, clearly visible',
        'watch' => ', worn on the wrist, clearly visible',
        'jewelry' => ', worn around the neck / on the wrist, clearly visible',
        _ => '',
      };

  /// Premium accessory studio: a slot the person currently wears NOTHING in
  /// (server sends item == 'none') — its alternatives are additions.
  bool _slotEmpty(int i) {
    final item = _slots![i].item.trim().toLowerCase();
    return item.isEmpty || item == 'none';
  }

  String _keyFor(Map<int, int> sel, {int? tuck}) {
    final t = tuck ?? _tuck;
    final ks = sel.keys.toList()..sort();
    final base = ks.map((k) => '$k:${sel[k]}').join('|'); // '' when nothing swapped
    return '$base${t == 0 ? '' : '|t$t'}'
        '${_sleeves == 0 ? '' : '|s$_sleeves'}${_layer == 0 ? '' : '|o$_layer'}';
  }

  /// Render the person wearing exactly this SET of swaps, composed off the
  /// ORIGINAL photo. Cached by the set — so any combination renders once and is
  /// then instant, and wearing (which only changes which set is "committed")
  /// never triggers a new render.
  /// User-visible renders currently in flight (taps, regenerations — never
  /// prefetch/thumb warms). Background workers YIELD while this is non-zero:
  /// concurrent warms were stealing Gemini's per-minute quota from the render
  /// the user was actually staring at (429 backoffs → the 40s swap).
  int _interactiveRenders = 0;
  Future<void> _yieldToInteractive() async {
    while (mounted && _interactiveRenders > 0) {
      await Future.delayed(const Duration(milliseconds: 400));
    }
  }

  Future<Uint8List> _renderSet(Map<int, int> sel,
      {int? tuck, String? regenNote, bool onBase = false, bool background = false}) {
    final t = tuck ?? _tuck;
    final key = _keyFor(sel, tuck: t);
    final existing = _cache[key];
    // regenNote set = user tapped "not right, regenerate" → force a fresh
    // render (bypass the cached combo); the note also busts the server cache.
    if (existing != null && regenNote == null) return existing;
    // NOW (no swaps) = the user's own look, verbatim and instant — never a
    // Gemini "normalize" pass (which could hallucinate garment changes and made
    // the entry state look like the PICK). Preference order: the pipeline's
    // clean cutout (typed argument), else auto-crop of the original photo.
    if (sel.isEmpty && t == 0 && _sleeves == 0 && _layer == 0) {
      // HARD LOCK on the transparent sprite: WAIT for isolation. The raw
      // camera asset is the last resort only when isolation is unavailable
      // on this device — debug builds flag that path loudly.
      final now = () async {
        final clean = _cleanBase ?? await _cleanFut;
        if (clean != null) return clean;
        assert(() {
          debugPrint('[editor] RAW FALLBACK: isolation yielded null — '
              'the unprocessed asset is backing the avatar');
          return true;
        }());
        return compute(autoCropSubject, _base).catchError((_) => _base);
      }();
      now.then((b) { _renderBytesSync[key] = b; }, onError: (_) {});
      return _cache[key] = now;
    }
    // Everything tuck-dependent lives in one builder so the DUAL-TUCK twin
    // gets its own instruction AND its own zones (tucking legally repaints
    // the bottoms' waistband; other states keep them pixel-frozen).
    ({String instruction, List<String> targetZones, List<String> lockedZones})
        buildSpec(int ts) {
      final changesList = (sel.keys.toList()..sort()).map((k) {
        final desc = _slots![k].alts[sel[k]! - 1].instruction;
        final anat = _anatomy(_slots![k].slot); // where a small accessory sits
        // Premium accessory studio: an empty slot (item == 'none') is an ADD —
        // "take OFF the none" would only confuse the model.
        if (_slotEmpty(k)) {
          return 'the ${_slots![k].slot} — ADD $desc$anat (they currently wear '
              'no ${_slots![k].slot})${_typeMandate(desc)}';
        }
        return 'the ${_slots![k].slot} — take OFF the ${_slots![k].item} and '
            'dress them in $desc$anat${_typeMandate(desc)}';
      }).toList();
      final tuckClause = switch (ts) {
        1 => 'The top MUST be fully TUCKED INTO the bottoms: its hem goes '
            'INSIDE the waistband, the waistband is clearly VISIBLE all the way '
            'across, and NO fabric of the top hangs below it. Redraw the '
            'waistband area of the bottoms as needed to show this — while the '
            'bottoms keep their exact color, pattern, fabric and length. An '
            'untucked or half-tucked top is a FAILED generation. ',
        2 => 'The top MUST be worn UNTUCKED — its hem hanging loose OVER the '
            'waistband, which is covered by the top. Untucking changes ONLY the '
            'hem position: the top itself is still the garment described above '
            '(same sleeves, same construction), NEVER the top from the source '
            'photo. A tucked top is a FAILED generation. ',
        _ => '',
      };
      // Sleeve / outer-layer clauses read instance state directly: the dual
      // tuck twin legitimately shares them (both twins wear the same sleeves).
      final sleeveClause = _sleeves == 1
          ? 'The sleeves of the top MUST be neatly ROLLED UP to just below the '
              'elbows, forearms visible. Rolling changes ONLY the sleeves — the '
              'garment itself (color, fabric, construction) stays exactly as '
              'described. If the top is short-sleeved, leave it untouched. '
          : '';
      final layerClause = _layer == 1
          ? 'Any OUTER layer (jacket, overshirt, coat, cardigan, blazer) MUST '
              'be worn fully OPEN — unbuttoned/unzipped, hanging naturally and '
              'showing the layer underneath. Opening changes ONLY how the outer '
              'layer hangs, never the garments themselves. If there is no outer '
              'layer, this instruction changes nothing. '
          : '';
      final fitTouchesTop = ts != 0 || _sleeves != 0 || _layer != 0;
      final tuckTouchesTop = ts != 0;
      bool slotAnchored(int i) =>
          !sel.containsKey(i) && !(fitTouchesTop && _slots![i].slot == 'top');
      bool slotPixelFrozen(int i) =>
          slotAnchored(i) && !(tuckTouchesTop && _slots![i].slot == 'bottom');
      final anchors = [
        for (var i = 0; i < _slots!.length; i++)
          // An empty accessory slot has nothing to keep — anchoring "the
          // glasses (none)" reads as an instruction to add none.
          if (slotAnchored(i) && !_slotEmpty(i))
            'the ${_slots![i].slot} (${_slots![i].item})',
      ];
      final anchorClause = anchors.isEmpty
          ? ''
          : 'Keep unchanged (same color, pattern, print direction, fit, length): '
              '${anchors.join(', ')}. ';
      final targetZones = {
        for (final k in sel.keys.toList()..sort()) _slots![k].slot,
        if (fitTouchesTop) 'top',
        if (tuckTouchesTop) 'waistband area of the bottoms',
      }.toList();
      final lockedZones = [
        for (var i = 0; i < _slots!.length; i++)
          if (slotPixelFrozen(i)) _slots![i].slot,
      ];
      const maskClause =
          'Face, hair, skin and pose stay identical to the source; the '
          'background is NOT protected — always replace it with the studio '
          'backdrop described below. ';
      const parityClause =
          'Render the new garment with EVERY stated attribute literally '
          '(sleeve length, fabric, color, fit, length). ';
      final swapRules = changesList.isEmpty
          ? ''
          : 'Every attribute of each swapped piece — color, '
              'pattern, fabric, cut, silhouette, sleeve length, neckline — comes '
              'from the NEW description alone; inherit NOTHING from the piece taken '
              'off, and no part of it may remain visible. The new garment MUST be '
              'clearly and visibly worn in the output; returning the outfit '
              'unchanged or leaving the original ${targetZones.join('/')} on is a '
              'FAILED generation. The source photo is used ONLY for the '
              'person\'s identity, body and pose — its swapped garments are '
              'discarded material. $parityClause';
      final changeSentence = changesList.isEmpty
          ? 'change ONLY how the top is worn — every garment itself stays '
              'identical (same garment, color, pattern, fabric)'
          : 'change ${changesList.join(', and ')}';
      final genderText = _genderNote.isEmpty ? '' : '${_genderNote.trim()} ';
      // Close-up framing only when the WHOLE change is small accessories
      // (watch/jewelry) — a waist-up crop would hide bottoms/shoes, so it's
      // never used when a garment is in the set.
      final framing = _isCloseUpSet(sel) ? _closeUpFraming : _framing;
      final instruction =
          'MANDATORY EDIT — this is the entire point of the task: on this person, '
          '$changeSentence. $tuckClause$sleeveClause$layerClause$swapRules$genderText$anchorClause$maskClause$framing';
      return (
        instruction: instruction,
        targetZones: targetZones,
        lockedZones: lockedZones
      );
    }

    final primary0 = buildSpec(t);
    // On a regenerate, the reason-tailored escalation note rides EVERY render
    // path (fast paint, feet retake, base upgrade) so all of them miss the
    // stale cache and correct the flagged mistake.
    final primary = regenNote == null
        ? primary0
        : (
            instruction: primary0.instruction + regenNote,
            targetZones: primary0.targetZones,
            lockedZones: primary0.lockedZones,
          );
    // DUAL TUCK (top swaps at natural state): render the tucked twin in the
    // SAME job — the row completes once with both images, and the toggle
    // becomes a purely local swap.
    final topIdx = _slots!.indexWhere((sl) => sl.slot == 'top');
    final dualTuck = _kFitControls &&
        _premiumNow &&
        t == 0 &&
        topIdx >= 0 &&
        sel.containsKey(topIdx) &&
        _slots!.any((sl) => sl.slot == 'bottom');
    final tuckedSpec = dualTuck ? buildSpec(1) : null;
    // Visual grounding: attach each swapped item's product shot (its rail
    // thumbnail — almost always already rendered and cached) so the model
    // COPIES the exact garment instead of reinterpreting the text ("light-wash
    // denim shorts" once came back as white trousers). Best-effort per item:
    // a missing thumb just means that swap renders text-only.
    // Top swap in this combo → render from the neutral base, not the photo
    // wearing the outgoing top (see _kNeutralInstr). Best-effort: if the base
    // isn't ready in 12s or failed, fall back to the classic path.
    final swapsTop = topIdx >= 0 && (sel[topIdx] ?? 0) > 0;
    final bottomIdx = _slots!.indexWhere((sl) => sl.slot == 'bottom');
    final swapsBottom = bottomIdx >= 0 && (sel[bottomIdx] ?? 0) > 0;
    final fut = () async {
      // Background warms wait their turn — the user's tap owns the quota.
      if (background) await _yieldToInteractive();
      final refs = await _swapRefs(sel);
      // FAST FIRST PAINT: render straight on the clean photo — ONE Gemini pass
      // (~15-20s), painted immediately. No automatic second "cut upgrade" pass
      // anymore (it doubled quota use and starved other renders): when the cut
      // DID inherit the source silhouette, the user's "Not right? → wrong item /
      // bad fit" regen re-renders ON the neutral base (onBase) — the fix runs
      // exactly when a human confirmed it's needed, not on every swap.
      Uint8List? base;
      if (onBase && swapsTop && !swapsBottom) {
        try {
          base = _neutralBase ??
              await _ensureNeutralBase().timeout(const Duration(seconds: 20));
        } catch (_) {/* fallback: clean-photo path */}
      }
      var bytes = await _gen(primary.instruction,
          targetZones: primary.targetZones,
          lockedZones: primary.lockedZones,
          references: refs.bytes,
          referenceUrls: refs.urls,
          referenceZones: refs.zones,
          referenceHints: refs.hints,
          // NEVER CHAIN ONTO THE PREVIOUS RENDER. Passing the last result made
          // every swap start from the one before it, so an artefact became the
          // next pass's input and multiplied: reported from the phone across six
          // taps — hands turned into blue blocks once trousers were swapped, then
          // the jeans came back cropped, then the shoes were dark smears. The skin
          // protection that keeps denim off a forearm samples skin FROM THE INPUT,
          // so once the hands were blue it stopped recognising them and the next
          // pass painted over them freely.
          //
          // `_swapRefs` already carries EVERY worn slot, and the engine already
          // dresses a clean base in order (full → upper → lower → shoes), so
          // sending no path at all is the whole fix: each tap re-renders the full
          // outfit from `.bare.png`. Three garments cost 4-6s instead of 1.5, and
          // in exchange the result depends only on WHAT is worn, never on the
          // order it was tapped in.
          personPath: null,
          comboKey: key,
          tucked: tuckedSpec,
          tuckedKey: dualTuck ? _keyFor(sel, tuck: 1) : null,
          personOverride: base);
      // FEET GUARD (client, deterministic): the aspect gate can't see a zoom
      // inside the same canvas, and model QA missed this thrice. A figure
      // touching the bottom edge = cropped → re-order up to TWICE, each under
      // a nonce'd fingerprint (a poisoned cache entry can never echo back as
      // its own retake), and RE-CHECK every result — the old single blind
      // retake shipped whatever came back. SKIPPED for accessory close-ups: a
      // waist-up crop legitimately has content at the bottom edge (no feet).
      // ONE feet retake max (server QA also checks framing) — a 2-retake cascade
      // stacked on the QA/identity retries pushed swaps past 50s.
      // …and only when the SOURCE was fine. This guard detects "the model
      // cropped the frame", which is a thing gpt-image did by zooming. Our own
      // engine cannot: it repaints inside a mask and composites back into the
      // original canvas, so the output geometry is the input's. On a photo the
      // user shot with their feet already near the bottom edge the check fired
      // every single time, and each retake was a second full render for nothing
      // — the observed two fix_renders rows and ~13s extra per tap.
      //
      // Comparing against the source makes it mean what its name says.
      var cropped = !_isCloseUpSet(sel) &&
          await _feetCropped(bytes) &&
          !await _feetCropped(base ?? _base);
      for (var attempt = 1; cropped && attempt <= 1; attempt++) {
        try {
          bytes = await _gen('${primary.instruction}${_retakeNote(attempt)}',
              targetZones: primary.targetZones,
              lockedZones: primary.lockedZones,
              references: refs.bytes,
              referenceUrls: refs.urls,
              referenceZones: refs.zones,
              referenceHints: refs.hints,
              comboKey: key,
              personOverride: base);
          cropped = await _feetCropped(bytes);
        } catch (_) {
          break; // guard must never block the render
        }
      }
      assert(() {
        if (cropped) debugPrint('[editor] FEET: still cropped after retakes ($key)');
        return true;
      }());
      return bytes;
    }();
    _cache[key] = fut;
    _rendering.add(key);
    if (!background) _interactiveRenders++;
    // Mirror zone-level "generating" into the shared OutfitState (post-frame:
    // _renderSet can run during build, when provider writes are illegal).
    final zones = [for (final k in sel.keys) _slots![k].slot];
    // _renderSet can be hit during build — never setState here. The post-frame
    // poke repaints the cards' progress strips when a render starts off-tap
    // (e.g. the background prefetch queue).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final z in zones) {
        ref.read(outfitStateProvider.notifier).setGenerating(z, true);
      }
      if (_rendering.contains(key)) setState(() {});
    });
    // Self-evict on failure: a timed-out/failed render must NOT stay cached as a
    // permanently-broken future (the old silent-stale bug) — the next tap on
    // this combo triggers a fresh API call instead.
    fut.then((b) {
      _renderBytesSync[key] = b;
    }, onError: (_) {
      if (identical(_cache[key], fut)) _cache.remove(key);
    }).whenComplete(() {
      if (!background && _interactiveRenders > 0) _interactiveRenders--;
      if (mounted) {
        setState(() => _rendering.remove(key));
        for (final z in zones) {
          ref.read(outfitStateProvider.notifier).setGenerating(z, false);
        }
      } else {
        _rendering.remove(key);
      }
    });
    return fut;
  }

  /// Build the per-item flat-lay references for a swap combo (the thumbs the
  /// model COPIES from). Thumbs are cached after first warm, so this is cheap
  /// on the second call — hence safe to run again for the Phase-2 upgrade.
  /// Returns garments in the SAME order buildSpec lists the zones (both walk
  /// `sel.keys..sort()`), plus that zone per garment — so the server can pair
  /// each reference with the body area it dresses. Without the zones the pairing
  /// was positional across two separate lists and broke as soon as one garment
  /// had a product photo and another did not, which sent every multi-zone swap
  /// to the hosted renderer.
  Future<({List<Uint8List> bytes, List<String> urls, List<String> zones, List<String> hints})>
      _swapRefs(Map<int, int> sel) async {
    final refs = <Uint8List>[];
    final urls = <String>[];
    final zones = <String>[];
    // SHORT GARMENT NAME per reference. The engine's text conditioning was
    // getting the first 200 chars of `instruction`, which is a composed prompt
    // starting with 'MANDATORY EDIT — this is the entire point…' — boilerplate
    // with no garment in it. IP-Adapter still transferred texture from the photo,
    // but text and image conditioning disagreed and the old colour survived (a
    // white linen shirt rendered as the previous black top with new sleeves).
    final hints = <String>[];
    for (final k in sel.keys.toList()..sort()) {
      final alt = _slots![k].alts[sel[k]! - 1];
      // PREFER THE REAL PRODUCT PHOTO. When an alternative was matched to an
      // actual SKU it carries that garment's own image URL, and passing the URL
      // beats generating a cut-out twice over: the renderer gets ground truth
      // instead of an AI re-drawing of it, and nothing has to be downloaded,
      // base64'd, POSTed and re-uploaded (2081 KB / 16.6s with bytes against
      // 642 KB / 10.3s with the URL, same swap). It also skips the _itemImage
      // render entirely — up to 12s of waiting before the swap even began.
      final shopUrl = (alt.shop?['imageUrl'] ?? '').toString();
      if (shopUrl.startsWith('http')) {
        urls.add(shopUrl);
        zones.add(_slots![k].slot);
        hints.add(alt.label);
        continue;
      }
      try {
        // No product photo (a wardrobe piece, or an idea with no SKU match):
        // fall back to the generated cut-out. 12s cap — past it the swap goes
        // text-only and the thumb keeps warming for the next tap.
        refs.add(await _itemImage(alt.instruction, _slots![k].slot)
            .timeout(const Duration(seconds: 12)));
        urls.add('');                     // placeholder keeps zones aligned
        zones.add(_slots![k].slot);
        hints.add(alt.label);
      } catch (_) {/* text-only for this item */}
    }
    return (bytes: refs, urls: urls, zones: zones, hints: hints);
  }

  // ── Smart Prefetch Queue — cost-capped background warming ─────────────────
  // Warms the EXACT combos a tap would render: the ACTIVE tab gets its PICK +
  // first IDEA composed over the user's CURRENT picks; the other tabs get
  // their PICK. Two renders in flight; tab taps and pick commits re-queue for
  // the new base — most swap taps then land on a warm cache instead of the
  // 10-25s hanger. The server-side tryon_cache dedupes repeats across
  // sessions, so re-warming a seen combo is a fast hit, not a fresh spend.
  final List<({Map<int, int> sel, int? tuck})> _prefetchQueue = [];
  int _prefetchWorkers = 0;
  // ONE background render at a time — two warm lanes plus the user's own tap
  // was 3 concurrent Gemini calls from one phone (429s → IMAGE_OTHER spiral).
  static const _prefetchConcurrency = 1;

  /// Top [take] alternatives of a tab as full render combos over the current
  /// picks: the stylist's PICK first, then the leading non-pick idea.
  List<Map<int, int>> _combosFor(int tab, {required int take}) {
    final slots = _slots;
    if (slots == null || tab >= slots.length || _locked.contains(tab)) return const [];
    final alts = slots[tab].alts;
    final order = <int>[
      for (var i = 0; i < alts.length; i++)
        if (alts[i].recommended) i + 1,
      for (var i = 0; i < alts.length; i++)
        if (!alts[i].recommended) i + 1,
    ];
    return [
      for (final a in order.take(take)) Map<int, int>.from(_picked)..[tab] = a,
    ];
  }

  /// Background warming EXISTED TO HIDE A SLOW RENDERER. At 45-60s per hosted
  /// render, pre-warming the combos a tap might need was the only way a swap ever
  /// felt instant. On our own engine a render is 2.6s — and the worker renders
  /// strictly one job at a time, so every warm sitting in the queue is a job the
  /// user's actual tap waits behind. Measured: three jobs 8s apart, each 2.4-2.9s
  /// of GPU, and a 22s wait for the tap that entered the queue last.
  ///
  /// So it is off. What it optimised no longer exists, and it now causes the delay
  /// it was built to prevent. Flip to true only if renders get slow again.
  static const bool _kPrefetchWarms = false;

  void _startPrefetchQueue() {
    if (!_kPrefetchWarms) return;
    final slots = _slots;
    if (slots == null) return;
    final open = _combosFor(_sel, take: 2);
    _prefetchQueue
      ..clear()
      ..addAll([
        if (open.isNotEmpty) (sel: open.first, tuck: null), // open tab's PICK
        // The base look's tucked state — top swaps warm their own twin via
        // dual generation; this covers toggling BEFORE any swap.
        if (_kFitControls &&
            _premiumNow &&
            slots.any((s) => s.slot == 'top') &&
            _tuck != 1)
          (sel: Map<int, int>.from(_picked), tuck: 1),
        for (final c in open.skip(1)) (sel: c, tuck: null), // first IDEA
        for (var i = 0; i < slots.length; i++)
          if (i != _sel)
            for (final c in _combosFor(i, take: 1)) (sel: c, tuck: null),
      ]);
    for (var i = 0; i < _prefetchConcurrency; i++) {
      _pumpPrefetch();
    }
  }

  Future<void> _pumpPrefetch() async {
    if (_prefetchWorkers >= _prefetchConcurrency) return;
    _prefetchWorkers++;
    try {
      while (_prefetchQueue.isNotEmpty && mounted) {
        // FOREGROUND FIRST: while ANY user-visible render is in flight (tap,
        // regen, wear), background warming yields — concurrent warms were
        // stealing Gemini's per-minute quota from the visible swap and turning
        // it into 429 backoffs / 502s (the "endless hanger").
        await _yieldToInteractive();
        if (!mounted) return;
        final item = _prefetchQueue.removeAt(0);
        if (_renderBytesSync.containsKey(_keyFor(item.sel, tuck: item.tuck))) {
          continue; // already warm
        }
        try {
          await _renderSet(item.sel, tuck: item.tuck, background: true);
        } catch (_) {/* evicted by _renderSet; renders on demand when tapped */}
      }
    } finally {
      _prefetchWorkers--;
    }
  }

  /// Tab/pick-driven priority: the newly relevant combos jump the queue,
  /// composed over the CURRENT picks (an older base would warm dead combos).
  void _prioritizePrefetch(int slot) {
    if (_kCollagePreview) return; // collage mode never prefetches renders
    final combos = [for (final c in _combosFor(slot, take: 2)) (sel: c, tuck: null)];
    final keys = {for (final c in combos) _keyFor(c.sel)};
    _prefetchQueue
      ..removeWhere((c) => c.tuck == null && keys.contains(_keyFor(c.sel)))
      ..insertAll(0, combos);
    for (var i = 0; i < _prefetchConcurrency; i++) {
      _pumpPrefetch();
    }
  }

  // ── Thumbnail warm pool — every category's item shots, 3 in flight ────────
  final List<(String desc, String slot)> _thumbQueue = [];
  int _thumbWorkers = 0;
  static const _thumbConcurrency = 3;

  void _startThumbWarm(List<_Slot> slots) {
    _thumbQueue
      ..clear()
      ..addAll([
        for (final sl in slots)
          for (final alt in sl.alts) (alt.instruction, sl.slot),
      ]);
    for (var i = 0; i < _thumbConcurrency; i++) {
      _pumpThumbWarm();
    }
  }

  Future<void> _pumpThumbWarm() async {
    if (_thumbWorkers >= _thumbConcurrency) return;
    _thumbWorkers++;
    try {
      while (_thumbQueue.isNotEmpty && mounted) {
        // Thumbs are the LOWEST priority: library hits are cheap HTTP, but a
        // library miss is a full Gemini render — never let it race a tap.
        await _yieldToInteractive();
        if (!mounted) return;
        final (desc, slot) = _thumbQueue.removeAt(0);
        if (_itemBytesSync.containsKey(desc)) continue;
        try {
          _itemBytesSync[desc] = await _itemImage(desc, slot);
          if (mounted) setState(() {}); // visible spinners swap in as thumbs land
        } catch (_) {/* renders on demand when its tab opens */}
      }
    } finally {
      _thumbWorkers--;
    }
  }

  /// The tapped tab's thumbnails jump the warm queue.
  void _prioritizeThumbs(int slot) {
    final name = _slots![slot].slot;
    final want = [
      for (final a in _slots![slot].alts)
        if (!_itemBytesSync.containsKey(a.instruction)) (a.instruction, name),
    ];
    if (want.isEmpty) return;
    final descs = {for (final w in want) w.$1};
    _thumbQueue
      ..removeWhere((e) => descs.contains(e.$1))
      ..insertAll(0, want);
    for (var i = 0; i < _thumbConcurrency; i++) {
      _pumpThumbWarm();
    }
  }

  Future<Uint8List> _current() => _renderSet(_effective);

  // ── "Not right? — regenerate" ─────────────────────────────────────────────
  // Reason → (i18n label key, prompt escalation note). The note rides EVERY
  // render path on the retry (fast paint, feet retake, base upgrade) so all
  // miss the stale cache and correct the flagged mistake; the reason also tags
  // the negative training pair for the future VTON model.
  static const Map<String, ({String key, String note})> _regenReasons = {
    'wrong_item': (key: 'editor.reasonWrongItem', note: ' REGENERATE — the previous render showed the WRONG garment. Copy the reference product shot EXACTLY: same garment type, colour, pattern and length; never substitute a different piece.'),
    'bad_fit': (key: 'editor.reasonBadFit', note: ' REGENERATE — the previous render fit the garment poorly. Fit it naturally to THIS body: correct proportions, natural drape, correct length, no distortion.'),
    'background': (key: 'editor.reasonBackground', note: ' REGENERATE — the previous render left background artifacts. The ENTIRE frame behind the person must be flat pure-white #FFFFFF: no halos, no grey patches, no cutout fringe.'),
    'not_me': (key: 'editor.reasonNotMe', note: ' REGENERATE — the previous render changed the person. Keep the EXACT same face, hairline, skin tone and body proportions from the person photo.'),
    'other': (key: 'editor.reasonOther', note: ' REGENERATE — the previous render was not right. Produce a cleaner, more accurate result faithful to the person and the reference garment.'),
  };
  final Map<String, int> _regenCount = {};

  void _openRegenSheet() {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.hero))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(
              child: Container(
                  width: 40, height: 5, margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(color: const Color(0xFFD8D8D4), borderRadius: BorderRadius.circular(10))),
            ),
            Text('editor.regenTitle'.tr(),
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: AppColors.ink)),
            const SizedBox(height: 4),
            Text('editor.regenSub'.tr(), style: const TextStyle(fontSize: 13, color: AppColors.muted)),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in _regenReasons.entries)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () { Navigator.of(ctx).pop(); _regenerate(e.key); },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        border: Border.all(color: AppColors.line)),
                    child: Text(e.value.key.tr(),
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.ink)),
                  ),
                ),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _regenerate(String reason) async {
    final key = _keyFor(_effective, tuck: _tuck);
    if ((_regenCount[key] ?? 0) >= 3) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('editor.regenCapped'.tr())));
      }
      return;
    }
    _regenCount[key] = (_regenCount[key] ?? 0) + 1;
    HapticFeedback.mediumImpact();
    // Negative-training signal: the WRONG bytes + inputs + reason (best-effort,
    // fire-and-forget — never blocks the regeneration).
    final wrong = _renderBytesSync[key];
    if (wrong != null) {
      final instr = _effective.entries
          .map((e) => '${_slots![e.key].slot}: ${_slots![e.key].alts[e.value - 1].instruction}')
          .join(' | ');
      () async {
        try {
          final refs = await _swapRefs(_effective);
          final clean = _cleanBase ?? await _cleanFut;
          await ref.read(looktokApiProvider).flagRender(
                reason: reason,
                instruction: instr,
                wrongB64: base64Encode(wrong),
                wrongMime: imageMime(wrong),
                personB64: clean != null ? base64Encode(clean) : null,
                personMime: clean != null ? imageMime(clean) : null,
                refs: [for (final r in refs.bytes) {'data': base64Encode(r), 'mimeType': imageMime(r)}],
              );
        } catch (_) {/* best-effort */}
      }();
    }
    // Force a fresh render: reason note + a nonce → unique fingerprint, both
    // client and server caches miss. Garment-related reasons re-render ON the
    // neutral base — the cut-correct canvas — exactly when a human confirmed
    // the cut/garment went wrong (this replaced the automatic phase-2 pass).
    final note = (_regenReasons[reason]?.note ?? _regenReasons['other']!.note) +
        ' [${DateTime.now().millisecondsSinceEpoch}]';
    final onBase = reason == 'wrong_item' || reason == 'bad_fit';
    _cache.remove(key);
    _renderBytesSync.remove(key);
    if (mounted) {
      setState(() =>
          _avatarFut = _renderSet(_effective, regenNote: note, onBase: onBase));
    }
  }

  // The stylist rating (1–10), live. Base = the review's score; each of the
  // stylist's recommended picks you're wearing nudges it up — so following the
  // advice visibly improves the score.
  int get _effectiveScore {
    var score = _analysis?.overallScore ?? widget.score ?? 6;
    final slots = _slots;
    if (slots != null) {
      for (final e in _effective.entries) {
        final s = slots[e.key];
        if (e.value >= 1 && e.value <= s.alts.length && s.alts[e.value - 1].recommended) score += 1;
      }
    }
    return score.clamp(1, 10);
  }

  // A white canvas to generate garment product shots onto (text → image).
  String get _white => _whiteBase ??= base64Encode(Uint8List.fromList(
        img.encodeJpg(img.Image(width: 512, height: 680)..clear(img.ColorRgb8(255, 255, 255))),
      ));

  /// Generate the garment ALONE as a clean product shot on white — no person.
  /// Used for the option thumbnails; cached per description. Cheap vs on-body.
  /// [slot] pins the category: without it, multi-piece descriptions rendered
  /// as 4-item outfit collages inside single-category tabs.
  // desc → ready library flat-lay URL (matched generated item). Present → the
  // thumbnail/reference is FETCHED, not Gemini-rendered (instant, zero cost).
  final Map<String, String> _libImg = {};

  /// Uniform item framing for BOTH sources (library + Gemini) — trim white
  /// margin, re-center on a square white canvas. Runs off the UI isolate.
  Future<Uint8List> _normThumb(Uint8List bytes) async {
    try {
      return await compute(normalizeItemThumb, bytes);
    } catch (_) {
      return bytes;
    }
  }

  Future<Uint8List> _itemImage(String desc, String slot) {
    final existing = _items[desc];
    if (existing != null) return existing;
    // Library fast path: a matched flat-lay — fetch a SMALL transformed copy
    // (Supabase render endpoint, ~400px) and use it AS-IS. No autoCrop compute
    // (flat-lays are already clean, centered on white) — that's what made it
    // feel slow. A 400px webp is ~20-40KB vs the ~1MB original.
    final libUrl = _libImg[desc];
    if (libUrl != null) {
      return _items[desc] = () async {
        try {
          final thumb = libUrl
              .replaceFirst('/object/public/', '/render/image/public/');
          final u = '$thumb${thumb.contains('?') ? '&' : '?'}width=400&quality=70';
          final r = await http.get(Uri.parse(u)).timeout(const Duration(seconds: 8));
          if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) return _normThumb(r.bodyBytes);
          // transform disabled? fall back to the raw object.
          final raw = await http.get(Uri.parse(libUrl)).timeout(const Duration(seconds: 8));
          if (raw.statusCode == 200 && raw.bodyBytes.isNotEmpty) return _normThumb(raw.bodyBytes);
        } catch (_) {/* fall through to generation */}
        return _generateItemImage(desc, slot);
      }();
    }
    return _items[desc] = _generateItemImage(desc, slot);
  }

  /// LOOKS-FIRST was an owner decision on 28.07 taken for ONE reason: a hosted
  /// render cost \$0.039 and 45-60s, so showing four ready looks was cheaper and
  /// less painful than letting anyone swap items freely.
  ///
  /// Both halves of that reasoning are gone. A dressing pass on our own engine is
  /// ~\$0.0003 and a single-garment swap is its BEST case — one pass instead of
  /// three, measured 10-12s end to end. Per-item browsing is now the cheaper mode,
  /// not the expensive one, so it goes back on. Flip to true to revert.
  static const bool _kLooksFirst = false;
  // Pre-render engine: ONE gpt-image-1 grid (real face via pixel composite,
  // 1 credit for all 4) instead of 4 parallel Gemini singles. false = revert.
  static const bool _kGridPrerender = true;
  List<(List<String> ids, String title, String boardUrl)> _lookCards = [];
  bool _lookBusy = false;
  String? _lookBusyKey;        // ONLY the tapped card shows progress
  bool _lookBoardsPending = false;
  /// Pre-rendered "user wearing look" bytes per look key. The server knows
  /// all four looks the moment cards exist — so we dress the avatar in ALL of
  /// them in parallel while the user reads the critique; a tap on a finished
  /// card swaps instantly. Owner's call 29.07: parallelize, don't wait.
  final Map<String, Uint8List> _lookRenders = {};
  final Set<String> _lookPrefetching = {};

  Future<void> _loadLookBoards(List<_Slot> slots) async {
    // Compose up to 4 outfits: k-th idea of top × k-th idea of bottom, only
    // library-matched pieces (they have ids + real product photos).
    List<(String, String)> picks(String slotName) {
      final i = slots.indexWhere((s) => s.slot == slotName);
      if (i < 0) return [];
      return [
        for (final a in slots[i].alts)
          if (a.shop?['id'] != null)
            (a.shop!['id'].toString(), a.shop!['name']?.toString() ?? a.label),
      ];
    }
    final tops = picks('top'), bottoms = picks('bottom');
    final api = ref.read(looktokApiProvider);
    Map<String, String> got;
    var combos = <(List<String>, String)>[];
    if (tops.isNotEmpty && bottoms.isNotEmpty) {
      final n = [tops.length, bottoms.length, 4].reduce((a, b) => a < b ? a : b);
      combos = [
        for (var k = 0; k < n; k++)
          ([tops[k].$1, bottoms[k].$1], '${tops[k].$2} + ${bottoms[k].$2}'),
      ];
      got = await api.lookBoards([for (final c in combos) c.$1],
          gender: _gender == 'neutral' ? null : _gender);
      // The server TOPS UP to four looks — keep its extras, don't filter the
      // response down to our own combos (that was the 1-card bug).
      final known = {for (final c in combos) c.$1.join('+')};
      combos = [
        ...combos,
        for (final k in got.keys)
          if (!known.contains(k)) (k.split('+'), 'Look'),
      ];
    } else {
      // No library matches in THIS review → the server composes looks from
      // the catalog itself. Cards must never depend on matching luck.
      got = await api.lookBoards(const [],
          auto: true, gender: _gender == 'neutral' ? null : _gender);
      combos = [for (final k in got.keys) (k.split('+'), 'Look')];
    }
    if (!mounted) return;
    // Dress the avatar in every look NOW — taps become instant.
    final renderable = [
      for (final c in combos)
        if (got[c.$1.join('+')] != null) c.$1,
    ];
    if (_kGridPrerender) {
      unawaited(_prefetchLookRendersGrid(renderable));
    } else {
      for (final ids in renderable) {
        unawaited(_prefetchLookRender(ids));
      }
    }
    setState(() {
      _lookBoardsPending = false;
      _lookCards = [
        for (final c in combos)
          if (got[c.$1.join('+')] != null) (c.$1, c.$2, got[c.$1.join('+')]!),
      ];
    });
  }

  /// All looks in ONE grid-vton call. Deliberately NOT registered in
  /// _lookPrefetching: a wear-tap mid-flight must preempt with its own fast
  /// render, not wait ~60s for the whole grid. Whatever finishes first wins;
  /// the grid only fills keys that are still empty.
  Future<void> _prefetchLookRendersGrid(List<List<String>> looks) async {
    if (looks.isEmpty) return;
    final api = ref.read(looktokApiProvider);
    final urls = await api.gridVton(looks);
    if (urls.isEmpty) {
      // No avatar / engine off / error → the proven per-look Gemini path.
      for (final ids in looks) {
        unawaited(_prefetchLookRender(ids));
      }
      return;
    }
    await Future.wait(urls.entries.map((e) async {
      if (_lookRenders[e.key] != null) return;
      try {
        final img = await http.get(Uri.parse(e.value))
            .timeout(const Duration(seconds: 30));
        if (img.statusCode == 200 && img.bodyBytes.isNotEmpty) {
          _lookRenders[e.key] = img.bodyBytes;
        }
      } catch (_) {/* tap path retries */}
    }));
    if (mounted) setState(() {}); // ready dots
    // Grid can miss a key (partial failure) — cover stragglers individually.
    for (final ids in looks) {
      if (_lookRenders[ids.join('+')] == null) {
        unawaited(_prefetchLookRender(ids));
      }
    }
  }

  /// Fetch "user wearing this look" into the local cache. Server-side render
  /// cache makes this idempotent — four parallel calls cost four renders ONCE
  /// per photo, then it's all cache.
  Future<Uint8List?> _prefetchLookRender(List<String> ids) async {
    final key = ids.join('+');
    if (_lookRenders[key] != null || !_lookPrefetching.add(key)) {
      return _lookRenders[key];
    }
    try {
      final api = ref.read(looktokApiProvider);
      final r = await api.generateVton(garmentIds: ids);
      final img = await http.get(Uri.parse(r.url)).timeout(const Duration(seconds: 30));
      if (img.statusCode == 200 && img.bodyBytes.isNotEmpty) {
        _lookRenders[key] = img.bodyBytes;
        if (mounted) setState(() {});   // card gets its "ready" dot
        return img.bodyBytes;
      }
    } catch (_) {/* tap path retries */} finally {
      _lookPrefetching.remove(key);
    }
    return null;
  }

  /// Tap a look card. Pre-rendered → instant swap. Not yet → the classic
  /// shimmer-over-photo wait (the FutureBuilder's own waiting branch), never
  /// a dead screen.
  Future<void> _wearLook(List<String> ids) async {
    final key = ids.join('+');
    final ready = _lookRenders[key];
    if (ready != null) {
      setState(() {
        _lastShown = ready;
        _renderBytesSync[_keyFor(_effective)] = ready;
        _avatarFut = Future.value(ready);
      });
      // NO "saved" toast here. Wearing a look is a PREVIEW — the only thing
      // that persists is the Save button (api.saveEditedLook). Claiming a save
      // on every tap trained the user to believe the app was saving behind
      // their back. The avatar visibly changing is the feedback.
      return;
    }
    if (_lookBusy) return;
    final wait = () async {
      final bytes = await _prefetchLookRender(ids);
      if (bytes == null) throw ApiException('Could not render the look — try again.');
      _lastShown = bytes;
      _renderBytesSync[_keyFor(_effective)] = bytes;
      return bytes;
    }();
    setState(() {
      _lookBusy = true;
      _lookBusyKey = key;
      // Clear the sync fast path so _avatar() falls through to the
      // FutureBuilder, whose waiting branch IS the old shimmer+timer UX.
      _renderBytesSync.remove(_keyFor(_effective));
      _avatarFut = wait;
    });
    try {
      await wait;
      // Same here: the render landing on the avatar is the confirmation.
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {/* surfaced by the FutureBuilder error branch */} finally {
      if (mounted) {
        setState(() {
          _lookBusy = false;
          _lookBusyKey = null;
        });
      }
    }
  }

  /// The EXACT instruction string is the server cache key — single and batch
  /// paths must compose it identically or they'd render every thumb twice.
  String _singlePrompt(String desc, String slot) =>
      'EXACTLY ONE $slot item, alone — never a full outfit, '
      'never multiple garments, never a collage or grid. '
      'LENGTH/TYPE PARITY (binding): render the EXACT garment type described '
      '— if it says shorts, draw actual above-knee SHORTS, never full-length '
      'trousers; if long trousers, never shorts; same for skirt vs '
      'dress.$_genderNote The item: $desc';

  /// One grid call for every idea WITHOUT a library match (~\$0.004/thumb
  /// instead of \$0.039) — fired once when slots land; misses fall back to
  /// the lazy per-item path transparently.
  Future<void> _batchThumbs(List<_Slot> slots) async {
    final byInstruction = <String, String>{}; // instruction → desc
    for (final s in slots) {
      for (final a in s.alts) {
        if (a.source != 'idea') continue;
        if (_libImg[a.instruction] != null) continue;   // library = free already
        if (_items[a.instruction] != null) continue;    // already in flight
        byInstruction[_singlePrompt(a.instruction, s.slot)] = a.instruction;
      }
    }
    if (byInstruction.isEmpty) return;
    final api = ref.read(looktokApiProvider);
    final take = byInstruction.entries.take(9).toList();
    final got = await api.generateItemsBatch(
      base64Image: _white,
      mimeType: 'image/jpeg',
      items: [for (final e in take) (instruction: e.key, slot: '')],
    );
    for (final e in take) {
      final bytes = got[e.key];
      if (bytes != null && bytes.isNotEmpty) {
        _items[e.value] = _normThumb(bytes);
      }
    }
    if (mounted) setState(() {});
  }

  Future<Uint8List> _generateItemImage(String desc, String slot) {
    return () async {
      final api = ref.read(looktokApiProvider);
      final single = _singlePrompt(desc, slot);
      Object? last;
      for (var i = 0; i < 3; i++) {
        try {
          final out = await api.generateItem(base64Image: _white, mimeType: 'image/jpeg', instruction: single);
          return _normThumb(out);
        } catch (e) {
          last = e;
        }
      }
      throw last ?? Exception('item render failed');
    }();
  }

  /// One-tap "Style the best look": for every slot the review flagged (or, absent
  /// a review, every slot) that you haven't kept, pick the stylist's recommended
  /// alternative. Composed off the original in one cached render.
  void _styleBest() {
    final slots = _slots;
    if (slots == null) return;
    HapticFeedback.mediumImpact();
    // "Style my WHOLE look" means every zone (owner call 21.07): the old
    // flagged-only pool quietly left unflagged slots in the user's own
    // clothes. Every slot gets its PICK; no marked pick → the strongest idea
    // (ideas arrive best-first); only Keep-locked slots are respected.
    final next = Map<int, int>.from(_picked);
    for (var i = 0; i < slots.length; i++) {
      if (_locked.contains(i)) continue; // never override a kept slot
      final alts = slots[i].alts;
      if (alts.isEmpty) continue;
      var ri = alts.indexWhere((a) => a.recommended);
      if (ri < 0) ri = 0;
      next[i] = ri + 1;
    }
    if (_keyFor(next) == _keyFor(_picked)) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Your look already works — nothing to restyle.')));
      return;
    }
    // Just commit the picks — the avatar renders the whole look and shows the
    // "Dressing you" loader while it does. Same interaction as picking one piece.
    setState(() {
      _picked
        ..clear()
        ..addAll(next);
      _alt = _picked[_sel] ?? 0;
      _syncAvatar();
    });
    // COST: no speculative pre-warm — combos render on demand when tapped.
  }

  // Switching slots is instant — the committed combo is already cached, so the
  // avatar doesn't re-render. Options for the new slot render only when tapped.
  Future<void> _pickSlot(int i) async {
    if (i == _sel) return;
    HapticFeedback.selectionClick();
    setState(() {
      _sel = i;
      _alt = _picked[i] ?? 0; // reflect this slot's worn pick, if any
      _syncAvatar();
    });
    _prioritizePrefetch(i); // this tab's PICK jumps the background queue
    _prioritizeThumbs(i); // …and its thumbnails jump the warm pool
  }

  void _pickAlt(int a) {
    if (_locked.contains(_sel)) return;
    HapticFeedback.selectionClick();
    setState(() {
      // A DIFFERENT top arrives in its natural state — carrying the previous
      // item's fit over left chips highlighted while the render showed the
      // natural state.
      if (_slots != null && _slots![_sel].slot == 'top' && a != _alt) {
        _tuck = 0;
        _sleeves = 0;
        _layer = 0;
      }
      _alt = a;
      if (_kCollagePreview) {
        // COLLAGE MODE: a tap COMMITS the pick to the board (browsing is free,
        // so no preview/commit split) — the paper-doll updates instantly, zero
        // renders. A combo that was already dressed for real shows its cached
        // photo instead of the sketch.
        if (a > 0) {
          _picked[_sel] = a;
        } else {
          _picked.remove(_sel);
        }
        final done = _renderBytesSync.containsKey(_keyFor(_effective, tuck: _tuck));
        _collage = _effective.isNotEmpty && !done;
        if (!_collage) _syncAvatar(); // NOW or an already-rendered combo
        return;
      }
      _syncAvatar(); // legacy: drive the main image from the new selection
    });
    // Legacy render-per-tap path. Kick the render NOW (fresh call if a previous
    // attempt failed and was evicted) and surface a failure instead of dying
    // silently.
    if (!_kCollagePreview && a > 0) {
      _current().then((_) {}, onError: (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Couldn’t render — check your connection, then tap the look to retry.')));
      });
    }
  }

  /// Keep the current garment for this slot — locks it so "Style my look" won't
  /// swap it. Used when you're happy with what's already on (the NOW item).
  void _toggleKeep() {
    HapticFeedback.selectionClick();
    setState(() {
      if (_locked.contains(_sel)) {
        _locked.remove(_sel);
      } else {
        _locked.add(_sel);
      }
    });
    _mirrorLocks();
  }

  /// Mirror the editor's lock set into [outfitStateProvider] (slot NAMES) so
  /// payload builders and other observers see the anchor zones.
  void _mirrorLocks() {
    final slots = _slots;
    if (slots == null) return;
    ref.read(outfitStateProvider.notifier)
        .setLocked({for (final i in _locked) slots[i].slot});
  }

  /// "Wear" — commit the previewed alternative to the look. Because the avatar
  /// already shows this exact combination (and it's cached), committing is
  /// INSTANT: no new render, and it stays on while you edit other slots.
  void _wear() {
    if (_alt == 0 || _locked.contains(_sel)) return;
    HapticFeedback.mediumImpact();
    setState(() => _picked[_sel] = _alt); // the previewed combo is already rendered
    // The base just changed — re-warm this tab's top combos over the NEW picks
    // so the user's likely next taps stay instant.
    _prioritizePrefetch(_sel);
  }

  // ── COLLAGE PREVIEW (paper-doll board) ────────────────────────────────────
  // Browsing is INSTANT and free: tapping an idea pins its flat-lay over the
  // avatar as an editorial collage cutout (deliberately a sketch, never fake
  // photorealism). The expensive Gemini render happens ONCE, when the user
  // commits the assembled look via "Dress me in this". Rollback: flip the flag
  // — every legacy render-per-tap path below is intact.
  static const bool _kCollagePreview = false;
  bool _collage = false; // true while the paper-doll board is what the avatar shows

  /// The one deliberate render: dress the assembled combo for real.
  void _dressMe() {
    if (_effective.isEmpty) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _collage = false;
      _syncAvatar(); // existing pipeline: scanner wait → photoreal result
    });
    _current().then((_) {}, onError: (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('Couldn’t render — check your connection, then tap the look to retry.')));
    });
  }

  /// Body-zone annotation targets: (y-fraction of the frame, cards on the
  /// RIGHT margin?). The person is NEVER covered — pieces live at the margins
  /// like a magazine spec sheet, a hairline pinning each to its zone. On-body
  /// paper-doll overlays were tried THREE ways (cards, keyed cutouts) and
  /// always read as amateur collage — real on-body preview needs the custom
  /// VTON model, not 2D compositing. Do not go back there.
  static const Map<String, (double, bool)> _collageZones = {
    'outerwear': (0.32, true),
    'top': (0.25, true),
    'belt': (0.46, true),
    'bottom': (0.58, true),
    'shoes': (0.88, true),
    'glasses': (0.08, false),
    'jewelry': (0.22, false),
    'watch': (0.52, false),
    'bag': (0.68, false),
    'accessories': (0.68, false),
  };

  Widget _collageView() {
    final base = _lastShown ?? _cleanBase;
    if (base == null) {
      // Cutout not ready yet (rare) — quiet studio while it lands.
      return const ColoredBox(color: _studioBg);
    }
    // The assembled pieces: every effective slot's chosen flat-lay. Missing
    // bytes kick a fetch (library = instant HTTP), placeholder meanwhile.
    final pins = <(String, Uint8List?)>[];
    for (final e in _effective.entries) {
      final slot = _slots![e.key].slot;
      final desc = _slots![e.key].alts[e.value - 1].instruction;
      final b = _itemBytesSync[desc];
      if (b == null) {
        _itemImage(desc, slot).then((v) {
          _itemBytesSync[desc] = v;
          if (mounted) setState(() {});
        }).catchError((_) {});
      }
      pins.add((slot, b));
    }
    return Container(
      color: _studioBg,
      child: LayoutBuilder(builder: (_, c) {
        final w = c.maxWidth, h = c.maxHeight;
        final cardW = (w * 0.24).clamp(72.0, 120.0);
        final cardH = cardW + 18; // square image + slot label
        // Per-side vertical layout at each zone's height, de-overlapped. The
        // RIGHT column reserves the bottom band for the "Dress me in this"
        // FAB (54h @ bottom:16) so a shoes card can never collide with it.
        final placed = <(String slot, Uint8List? bytes, double y, bool right)>[];
        for (final side in const [true, false]) {
          final maxY = h - cardH - (side ? 96.0 : 8.0);
          final sidePins = [
            for (final p in pins)
              if ((_collageZones[p.$1] ?? (0.5, true)).$2 == side) p
          ]..sort((a, b) => (_collageZones[a.$1] ?? (0.5, true))
              .$1
              .compareTo((_collageZones[b.$1] ?? (0.5, true)).$1));
          final start = placed.length;
          var prevBottom = -1e9;
          for (final p in sidePins) {
            var y = ((_collageZones[p.$1] ?? (0.5, true)).$1) * h - cardH / 2;
            y = y.clamp(8.0, maxY);
            if (y < prevBottom + 12) y = prevBottom + 12;
            prevBottom = y + cardH;
            placed.add((p.$1, p.$2, y, side));
          }
          // The de-overlap pass can push the column past the reserved band —
          // shift the whole side up by the overflow (floor at the top inset).
          if (placed.length > start) {
            final over = placed.last.$3 - maxY;
            if (over > 0) {
              for (var i = start; i < placed.length; i++) {
                placed[i] = (
                  placed[i].$1, placed[i].$2,
                  (placed[i].$3 - over).clamp(8.0, maxY), placed[i].$4,
                );
              }
            }
          }
        }
        return Stack(children: [
          // The person, untouched and fully visible.
          Positioned.fill(
              child: Image.memory(base, fit: BoxFit.contain, gaplessPlayback: true)),
          // Hairline pins under the cards.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _CollagePins([
                  for (final p in placed)
                    (
                      Offset(p.$4 ? w - 10 - cardW : 10 + cardW, p.$3 + cardW / 2),
                      Offset(w * 0.5, ((_collageZones[p.$1] ?? (0.5, true)).$1) * h),
                    ),
                ]),
              ),
            ),
          ),
          for (var i = 0; i < placed.length; i++)
            Positioned(
              left: placed[i].$4 ? null : 10,
              right: placed[i].$4 ? 10 : null,
              top: placed[i].$3,
              width: cardW,
              // Strict vertical rail; uniform 12% inner margin gives every
              // garment the same visual weight regardless of its own framing.
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  clipBehavior: Clip.antiAlias,
                  height: cardW,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.line),
                    boxShadow: const [
                      BoxShadow(color: Color(0x1A000000), blurRadius: 10, offset: Offset(0, 4)),
                    ],
                  ),
                  padding: EdgeInsets.all(cardW * 0.12),
                  child: placed[i].$2 != null
                      ? Image.memory(placed[i].$2!, fit: BoxFit.contain, gaplessPlayback: true)
                      : const Center(
                          child: SizedBox(
                              width: 14, height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.muted))),
                ),
                const SizedBox(height: 3),
                Text(_pretty(placed[i].$1).toUpperCase(),
                    style: const TextStyle(
                        fontSize: 8.5, fontWeight: FontWeight.w800,
                        letterSpacing: 1.1, color: AppColors.muted)),
              ]),
            ),
        ]);
      }),
    );
  }

  Future<void> _save() async {
    // A guest's look must be named so history reads "Victoria's look" (§14.10).
    String? subjectName;
    if (widget.subject.isGuest) {
      subjectName = widget.subject.name ?? _guestName ?? (await promptSubjectName(context))?.trim();
      if (subjectName == null || subjectName.isEmpty || !mounted) return; // cancelled
      _guestName = subjectName;
    }
    setState(() => _saving = true);
    try {
      final api = ref.read(looktokApiProvider);
      // Save exactly what's on the avatar — the effective combo is already
      // rendered and cached, so this is instant.
      final out = await _renderSet(_effective);
      await api.saveEditedLook(out, subjectName: subjectName);
      // Also tag the auto-saved fit review so the reopened read shows the name.
      final gid = _analysis?.generationId;
      if (subjectName != null && gid != null) {
        try {
          await api.nameGeneration(gid, subjectName);
        } catch (_) {/* best-effort */}
      }
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Saved to My Looks')));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Could not save')));
      }
    }
  }

  /// Re-render the currently shown image (a render can flake on entry under load).
  /// Hard reset Error → Loading: evict every trace of the failed attempt AND
  /// assign a NEW Future identity via _syncAvatar(). Without that reassignment
  /// the FutureBuilder kept watching the already-failed future — the old
  /// "tap retry, nothing happens" bug.
  void _retryCurrent() {
    HapticFeedback.selectionClick();
    setState(() {
      final key = _keyFor(_effective);
      _cache.remove(key);
      _renderBytesSync.remove(key);
      _rendering.remove(key);
      _syncAvatar(); // fresh future → the waiting branch mounts immediately
    });
  }


  // ── UI ─────────────────────────────────────────────────────────────────────

  /// The avatar fills the whole area (BoxFit.cover) so the person reads big with
  /// no black letterbox. Pinch to zoom IN only — can't zoom out past the fill
  /// (minScale 1), which is what caused the "zoom-out reveals black" glitch.
  Widget _zoomable(Widget child) {
    return LayoutBuilder(
      builder: (_, cons) => InteractiveViewer(
        transformationController: _zoom,
        minScale: 1,
        maxScale: 5,
        clipBehavior: Clip.hardEdge,
        // Studio-grey backing so the contained image's margins blend seamlessly
        // (no black bars) — matches the normalized render background.
        child: Container(
          width: cons.maxWidth,
          height: cons.maxHeight,
          color: _studioBg,
          child: child,
        ),
      ),
    );
  }

  /// Segmented "Tucked | Untucked" pill, in the sheet's register (white on
  /// ivory, hairline border — no floating shadow). Tap selects; each state is
  /// its own cache key, so flipping back to a seen state is instant.
  Widget _tuckToggle() {
    Widget seg(String label, int v) {
      // NO unselected state (owner constraint): the natural render is worn
      // untucked, so auto (_tuck == 0) HIGHLIGHTS "Untucked" — what's on the
      // avatar and what the toggle shows can never desynchronize.
      final on = v == 1 ? _tuck == 1 : _tuck != 1;
      return GestureDetector(
        onTap: () {
          if (on) return; // already the shown state — nothing to do
          Analytics.premiumFeatureTapped('tucked_untucked');
          HapticFeedback.selectionClick();
          setState(() {
            _tuck = v == 1 ? 1 : 0; // Untucked = the natural (auto) state
            _syncAvatar();
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: on ? AppColors.ink : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w700,
                  color: on ? Colors.white : AppColors.ink)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE6E3DC)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg('Tucked', 1),
        seg('Untucked', 2),
      ]),
    );
  }

  /// On/off chip for a single fit dimension (sleeves rolled, jacket open),
  /// styled like the slot rail's pills. Off = the natural render, on = the
  /// forced state — its own cache key, so a seen state flips back instantly.
  Widget _fitChip(String label, bool on, VoidCallback flip, String analytics) {
    return GestureDetector(
      onTap: () {
        Analytics.premiumFeatureTapped(analytics);
        HapticFeedback.selectionClick();
        setState(() {
          flip();
          _syncAvatar();
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: on ? AppColors.ink : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: on ? AppColors.ink : const Color(0xFFE6E3DC)),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w700,
                color: on ? Colors.white : AppColors.ink)),
      ),
    );
  }

  /// What the person is CURRENTLY wearing on top — the selected alternative's
  /// description, or the original item when nothing is swapped.
  String _effectiveTopDesc() {
    final topIdx = _slots?.indexWhere((sl) => sl.slot == 'top') ?? -1;
    if (topIdx < 0) return '';
    final alt = _effective[topIdx];
    if (alt != null && alt > 0) return _slots![topIdx].alts[alt - 1].instruction;
    return _slots![topIdx].item;
  }

  /// "Sleeves rolled" only makes sense on a long-sleeved garment. Allow-list:
  /// hide by default — a nonsense chip ("roll the sleeves" on a tee) reads as
  /// broken, a missing chip reads as smart.
  static final _longSleeved = RegExp(
      r'long[- ]sleeve|hoodie|sweater|jumper|cardigan|sweatshirt|blazer|'
      r'jacket|coat|overshirt|turtleneck|pullover|flannel|henley|'
      r'button[- ](up|down)|oxford|dress shirt|linen shirt|denim shirt',
      caseSensitive: false);
  static final _shortSleeved = RegExp(
      r'short[- ]sleeve|sleeveless|\btee\b|t[- ]shirt|tank|camisole|\bvest\b|polo',
      caseSensitive: false);
  bool get _sleevesRelevant {
    final d = _effectiveTopDesc();
    return _longSleeved.hasMatch(d) && !_shortSleeved.hasMatch(d);
  }

  /// "Jacket open" only for an openable layer.
  static final _openable = RegExp(
      r'jacket|coat|blazer|cardigan|overshirt|shacket|parka|bomber|trench|'
      r'windbreaker|anorak|gilet|zip[- ]up|button[- ](up|down)',
      caseSensitive: false);
  bool get _layerRelevant => _openable.hasMatch(_effectiveTopDesc());

  /// The Premium fit strip: ONE horizontal row inside the sheet, between
  /// the slot rail and the alternatives — a micro "FIT" label, the tuck pill
  /// and the relevance-gated chips. Top tab only. Premium-only: everyone SEES
  /// the controls (locked features sell); non-premium taps open the paywall
  /// with Premium preselected. Each chip appears ONLY when it makes sense on
  /// the worn garment (owner call 23.07).
  Widget _fitStrip() {
    final sleeves = _sleevesRelevant;
    final layer = _layerRelevant;
    // A state whose chip just became irrelevant (tee after a shirt) must not
    // keep silently flavouring render instructions.
    if (!sleeves && _sleeves != 0) _sleeves = 0;
    if (!layer && _layer != 0) _layer = 0;
    final premium =
        ref.watch(entitlementProvider).valueOrNull?['premium'] == true;
    final row = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(children: [
        Text(premium ? 'FIT' : 'FIT · PREMIUM',
            style: const TextStyle(
                fontSize: 9.5, fontWeight: FontWeight.w800,
                letterSpacing: 1.3, color: AppColors.muted)),
        if (!premium) ...[
          const SizedBox(width: 4),
          const Icon(Icons.lock, size: 11, color: AppColors.muted),
        ],
        const SizedBox(width: 10),
        _tuckToggle(),
        if (sleeves) ...[
          const SizedBox(width: 8),
          _fitChip('Sleeves rolled', _sleeves == 1,
              () => _sleeves = _sleeves == 1 ? 0 : 1, 'sleeves_rolled'),
        ],
        if (layer) ...[
          const SizedBox(width: 8),
          _fitChip('Jacket open', _layer == 1,
              () => _layer = _layer == 1 ? 0 : 1, 'jacket_open'),
        ],
      ]),
    );
    if (premium) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Analytics.premiumFeatureTapped('fit_panel_locked');
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const PaywallScreen(initialPlan: 0)));
      },
      child: AbsorbPointer(child: Opacity(opacity: 0.55, child: row)),
    );
  }

  Widget _avatar() {
    // COLLAGE MODE: while the user assembles a look, the avatar is the instant
    // paper-doll board — zero renders. "Dress me in this" flips _collage off
    // and the classic pipeline below takes over.
    if (_kCollagePreview && _collage && _effective.isNotEmpty) {
      return _collageView();
    }
    // Contain, on top of the auto-crop: the render is trimmed tight to the person
    // (autoCropSubject strips the studio margins), so `contain` makes that person
    // fill the frame edge-to-edge with NO stretch and NO head/feet cut. Any
    // remaining margin falls on the studio-grey backing — grey, not white.
    const fit = BoxFit.contain;
    const align = Alignment.center;
    final comboKey = _keyFor(_effective);
    // Session-cache fast path: an already-generated combination paints
    // synchronously — no FutureBuilder, no loader, instant swap.
    final sync = _renderBytesSync[comboKey];
    if (sync != null) {
      _lastShown = sync;
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
              scale: Tween(begin: 0.98, end: 1.0).animate(
                  CurvedAnimation(parent: anim, curve: Curves.easeOut)),
              child: child),
        ),
        layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
        child: KeyedSubtree(
          key: ValueKey('img-$comboKey'),
          child: Image.memory(sync,
              fit: fit, alignment: align, gaplessPlayback: true, width: double.infinity, height: double.infinity),
        ),
      );
    }
    final fut = _avatarFut ?? _current();
    // FutureBuilder resubscribes when the future's identity changes (per combo),
    // so selection changes always re-sync. The AnimatedSwitcher lives INSIDE and
    // fades between combo-keyed children (300ms, no blink, no layout shift —
    // every child is expanded to the full container).
    return FutureBuilder<Uint8List>(
      future: fut,
      builder: (_, s) {
        Widget child;
        if (s.connectionState != ConnectionState.done) {
          // NON-BLOCKING wait: hold the LAST successful render, fully visible,
          // under the scanner — no veil, no spinner, no dead screen. The
          // garment being previewed rides the scanner as a floating card.
          final dressing = _alt > 0 && _slots != null
              ? _itemBytesSync[_slots![_sel].alts[_alt - 1].instruction]
              : null;
          child = KeyedSubtree(
            key: ValueKey('wait-$comboKey'),
            child: _lastShown != null
                ? Stack(fit: StackFit.expand, children: [
                    Image.memory(_lastShown!, fit: fit, alignment: align),
                    _AvatarShimmer(
                        item: dressing,
                        overImage: true,
                        // Timer ONLY while picking/swapping (slots exist); on the
                        // initial load/generation loader (slots==null) — no timer.
                        showTimer: _slots != null,
                        zone: _slots != null ? _slots![_sel].slot : null),
                  ])
                : _AvatarShimmer(
                    item: dressing,
                    showTimer: _slots != null,
                    backdrop: _cleanBase ?? _base),
          );
        } else if (s.hasError || s.data == null) {
          // Reason-specific copy: the resilient API layer maps timeouts/dead
          // sockets/busy servers to clean ApiException messages — surface them
          // instead of one generic mystery line.
          final reason = s.error is ApiException
              ? s.error.toString()
              : 'Couldn’t render this look.';
          child = KeyedSubtree(
            key: ValueKey('err-$comboKey'),
            child: ColoredBox(
              color: _studioBg,
              child: Center(
                child: GestureDetector(
                  onTap: _retryCurrent,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.refresh, color: AppColors.ink),
                      const SizedBox(height: 6),
                      Text(reason,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.ink, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      const Text('Tap to retry',
                          style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
                    ]),
                  ),
                ),
              ),
            ),
          );
        } else {
          _lastShown = s.data; // remember for the next optimistic wait (no setState needed)
          child = KeyedSubtree(
            key: ValueKey('img-$comboKey${_slots == null ? '-scan' : ''}'),
            child: _slots == null
                // Slots still resolving (e.g. entry from Compare's "Improve
                // this look"): the photo is up, but the sheet can't exist yet
                // — the scanner overlay says "I'm reading this look" instead
                // of a silent, dead-looking screen.
                ? Stack(fit: StackFit.expand, children: [
                    Image.memory(s.data!,
                        fit: fit, alignment: align, gaplessPlayback: true,
                        width: double.infinity, height: double.infinity),
                    // Initial detection = "loading" screen → no timer.
                    const _AvatarShimmer(overImage: true, showTimer: false),
                  ])
                : Image.memory(s.data!,
                    fit: fit, alignment: align, gaplessPlayback: true, width: double.infinity, height: double.infinity),
          );
        }
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: ScaleTransition(
                scale: Tween(begin: 0.98, end: 1.0).animate(
                    CurvedAnimation(parent: anim, curve: Curves.easeOut)),
                child: child),
          ),
          layoutBuilder: (current, previous) => Stack(
            fit: StackFit.expand,
            children: [...previous, ?current],
          ),
          child: child,
        );
      },
    );
  }

  // ── Targeted regeneration: "give me a different idea for THIS slot" ──────
  // Appends a fresh alternative (varied direction so the cache key is new) and
  // previews it — only this category re-renders; the rest of the look holds.
  int _freshCount = 0;
  static const _freshDirections = [
    'a completely different, stylish alternative in another colour',
    'a bolder, more fashion-forward alternative',
    'a more relaxed, understated alternative',
    'a sharper, more polished alternative',
  ];
  void _refreshSlot() {
    final slots = _slots;
    if (slots == null || _locked.contains(_sel)) return;
    HapticFeedback.selectionClick();
    final slot = slots[_sel].slot;
    final dir = _freshDirections[_freshCount % _freshDirections.length];
    _freshCount++;
    final alt = _Alt(
      label: 'Fresh idea',
      source: 'idea',
      instruction: '$dir for the $slot (take #$_freshCount)',
      why: 'A fresh direction for your $slot.',
    );
    setState(() {
      slots[_sel].alts.add(alt);
      _alt = slots[_sel].alts.length; // preview it (renders just this combo)
      _syncAvatar();
    });
  }

  Widget _refreshTile() {
    return GestureDetector(
      onTap: _refreshSlot,
      child: Container(
        width: 58,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(color: AppColors.line),
        ),
        child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.refresh, size: 20, color: AppColors.ink),
          SizedBox(height: 4),
          Text('NEW', style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w700, letterSpacing: 1, color: AppColors.muted)),
        ]),
      ),
    );
  }

  Widget _thumb(int a) {
    final locked = _locked.contains(_sel);
    final sel = a == _alt;
    Widget inner;
    // cacheWidth ≈ thumb width @3x: decoded frames live in Flutter's ImageCache
    // (same bytes instance + same cacheWidth = cache hit), so remounts never
    // re-decode. Sync-cache hit = no FutureBuilder at all → instant tab switch.
    const thumbDecodeW = 180;
    if (a == 0) {
      // NOW = the current look (person). Original photo backs it while cropping.
      final nb = _itemBytesSync['~now'] ?? _cleanBase;
      inner = nb != null
          ? Image.memory(nb, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: thumbDecodeW)
          : FutureBuilder<Uint8List>(
              future: _renderSet(const {}),
              builder: (_, s) {
                if (s.connectionState == ConnectionState.done && s.hasData) {
                  _itemBytesSync['~now'] = s.data!;
                  return Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: thumbDecodeW);
                }
                // Never the raw asset — a quiet studio box while NOW bakes.
                return const ColoredBox(color: _studioBg);
              },
            );
    } else {
      // The garment ALONE (product shot, no person) — cheap; on-body render only
      // happens when the user actually taps it.
      final desc = _slots![_sel].alts[a - 1].instruction;
      final ib = _itemBytesSync[desc];
      inner = ib != null
          ? Padding(
              padding: const EdgeInsets.all(3),
              child: Image.memory(ib, fit: BoxFit.contain, gaplessPlayback: true, cacheWidth: thumbDecodeW))
          : FutureBuilder<Uint8List>(
              future: _itemImage(desc, _slots![_sel].slot),
              builder: (_, s) {
                if (s.connectionState == ConnectionState.done && s.hasData) {
                  _itemBytesSync[desc] = s.data!;
                  return Padding(
                      padding: const EdgeInsets.all(3),
                      child: Image.memory(s.data!, fit: BoxFit.contain, gaplessPlayback: true, cacheWidth: thumbDecodeW));
                }
                return const ColoredBox(
                    color: Color(0xFFFFFFFF),
                    child: Center(
                        child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))));
              },
            );
    }
    // This card's on-body combo: current worn picks with THIS alternative in
    // the active slot. In _rendering → its render (tap- or prefetch-started)
    // is in flight right now → show the micro-progress strip.
    final cardCombo = Map<int, int>.from(_picked);
    if (a == 0) {
      cardCombo.remove(_sel);
    } else {
      cardCombo[_sel] = a;
    }
    final generating = _rendering.contains(_keyFor(cardCombo));
    final rec = a > 0 && _slots![_sel].alts[a - 1].recommended;
    final owned = a > 0 && _slots![_sel].alts[a - 1].source == 'wardrobe';
    // Owned pieces carry ONLY the hanger icon (no text badge) — cleaner card.
    final badge = a == 0 ? 'NOW' : (rec ? 'PICK' : (owned ? '' : 'IDEA'));
    // NOW (your original) reads BLACK when selected; the recommended pick reads
    // cobalt — so they never look the same.
    // SELECTION owns the border: ONLY the active item is blue (2px). Status
    // (PICK star/badge) never colours the border — one clear visual hierarchy.
    final Color borderColor = sel ? AppColors.signature : AppColors.line;
    return GestureDetector(
      onTap: locked ? null : () => _pickAlt(a),
      child: Opacity(
        opacity: locked && a != 0 ? 0.4 : 1,
        child: Container(
          width: 58, height: 74,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.control),
            border: Border.all(color: borderColor, width: sel ? 2 : 1),
          ),
          child: Stack(fit: StackFit.expand, children: [
            inner,
            // Owned piece → "In your closet" marker (compact, top-left).
            if (owned) const Positioned(top: 4, left: 4, child: ClosetBadge(compact: true)),
            if (badge.isNotEmpty)
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                    color: rec ? AppColors.signature : const Color(0xCC0A0A0A),
                    borderRadius: BorderRadius.circular(5)),
                child: Text(badge,
                    style: const TextStyle(
                        fontSize: 7, fontWeight: FontWeight.w800, letterSpacing: 0.7, color: Colors.white)),
              ),
            ),
            // Micro-progress: this item's on-body render is in flight (via tap
            // OR background prefetch) — a 2px cobalt strip along the top edge.
            if (generating)
              const Positioned(
                top: 0, left: 0, right: 0,
                child: SizedBox(
                  height: 2,
                  child: LinearProgressIndicator(
                      backgroundColor: Colors.transparent, color: AppColors.signature),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  /// Clean fallback when the strict filter leaves no valid single items.
  Widget _emptyRailNote() {
    return Container(
      width: 150, height: 74,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.line),
      ),
      child: const Text('No single items for this category — tap ↻ for a fresh idea.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, fontSize: 10.5, height: 1.3)),
    );
  }

  String _pretty(String slot) {
    final key = 'editor.slot.$slot';
    final t = key.tr();
    return t == key ? slot[0].toUpperCase() + slot.substring(1) : t;
  }

  @override
  Widget build(BuildContext context) {
    final slots = _slots;
    // LOADER (initial detection, slots still null): a clean, full-bleed scanner
    // — NO app bar, NO SafeArea insets, background edge-to-edge to the very
    // bottom (owner 23.07: "на лоадере ничего наверху, фон до самого низа без
    // дырок"). The moment slots resolve, build() re-runs into the editor below.
    if (slots == null && _error == null) {
      return Scaffold(
        backgroundColor: const Color(0xFFEAE7E1), // taupe studio, matches scanner base
        resizeToAvoidBottomInset: false,
        body: SizedBox.expand(child: _avatar()),
      );
    }
    return Scaffold(
      // White so the sheet's rounded top corners never reveal black notches.
      backgroundColor: _studioBg,
      // The bar is ALWAYS there — the user lands on Edit Look immediately and
      // never sees a standalone loader screen (owner constraint 19.07).
      appBar: AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              elevation: 0,
              // The bar says WHAT is being fitted: the active zone once the
              // sheet is up, the flow name before that.
              title: Text(slots == null
                  ? 'editor.title'.tr()
                  : '${_pretty(slots[_sel].slot)} · ${'editor.title'.tr()}'),
              actions: [
                TextButton(
                  onPressed: _saving || slots == null ? null : _save,
                  child: _saving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text('common.save'.tr(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
      body: SafeArea(
        child: _error != null
            ? Center(child: Text(_error!, style: const TextStyle(color: AppColors.muted)))
            : Column(
                    children: [
                      Expanded(
                        child: Stack(children: [
                          Positioned.fill(child: _zoomable(_avatar())),
                          // WEAR — a round primary FAB over the avatar's
                          // bottom-right (best-practice affordance). Collage
                          // mode: "Dress me in this" — the ONE deliberate
                          // render of the assembled board. Legacy: "Wear this"
                          // commits the previewed (already-rendered) alt.
                          if (_kCollagePreview
                              ? (_collage && _effective.isNotEmpty)
                              : _alt > 0)
                            Positioned(
                              right: 16, bottom: 16,
                              child: _WearFab(
                                  busy: false,
                                  label: _kCollagePreview ? 'editor.dressMe'.tr() : null,
                                  onTap: _kCollagePreview ? _dressMe : _wear),
                            ),
                          // Fit controls moved INTO the sheet (under the slot
                          // rail) — floating pills over the photo read as
                          // clutter (owner call 23.07).
                          // Latent streaming: the render crystallizes out of
                          // blur while the GPU denoises. Invisible until the
                          // first preview lands, so a cold engine changes
                          // nothing about the existing loader.
                          if (_streamRenderId != null)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: ProgressiveGarmentStream(
                                  renderId: _streamRenderId!,
                                  placeholder: const SizedBox.shrink(),
                                  // Same contain as the final avatar: the preview
                                  // is the SAME frame at low res, and a fit
                                  // mismatch made it read as a tiny floating
                                  // figure rather than the image forming.
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                          // The QA replacement is in flight for THIS combo —
                          // say so instead of looking like a failed edit.
                          if (_refining.contains(_keyFor(_effective)))
                            Positioned(
                              left: 0, right: 0, bottom: 14,
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 11, vertical: 6),
                                  decoration: BoxDecoration(
                                      color: const Color(0xC00A0A0A),
                                      borderRadius: BorderRadius.circular(999)),
                                  child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(
                                          width: 9, height: 9,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 1.5,
                                              color: Colors.white),
                                        ),
                                        SizedBox(width: 7),
                                        Text('Perfecting the fit…',
                                            style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700)),
                                      ]),
                                ),
                              ),
                            ),
                        ]),
                      ),
                  if (slots != null)
                  Container(
                    decoration: const BoxDecoration(
                      // Warm ivory (reference register) — reads editorial, not
                      // utility-white; cards and pills float on it.
                      color: Color(0xFFF2F0EB),
                      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.hero)),
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Collapse handle — the standard iOS pill; tap to drop the
                        // panel and see the photo full-screen, tap again to return.
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _sheetOpen = !_sheetOpen),
                          child: SizedBox(
                            height: 22,
                            child: Center(
                              child: Container(
                                width: 40,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFD8D8D4),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (_sheetOpen)
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // ONE short line + a per-slot Keep toggle. For an
                              // alternative it's the rationale (names the piece + why,
                              // in one sentence); for NOW it's the one-line read.
                              Builder(builder: (_) {
                                final isAlt = _alt > 0;
                                final alt = isAlt ? slots[_sel].alts[_alt - 1] : null;
                                final line = isAlt
                                    ? ((alt!.why?.isNotEmpty ?? false) ? alt.why! : alt.label)
                                    : ((_analysis?.overallSummary.isNotEmpty ?? false)
                                        ? _analysis!.overallSummary
                                        : slots[_sel].item);
                                final kept = _locked.contains(_sel);
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Rating row: typographic Style Score (left).
                                    // Wear moved to a round FAB over the avatar
                                    // (bottom-right); Keep stays here for NOW.
                                    Row(children: [
                                      _StyleScore(score100: _effectiveScore * 10),
                                      const Spacer(),
                                      // "Not right?" — flag the render as wrong
                                      // (negative training sample) + regenerate.
                                      GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: _openRegenSheet,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: BorderRadius.circular(AppRadius.pill),
                                            border: Border.all(color: AppColors.line),
                                          ),
                                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                                            const Icon(Icons.refresh, size: 14, color: AppColors.inkSoft),
                                            const SizedBox(width: 5),
                                            Text('editor.notRight'.tr(),
                                                style: const TextStyle(
                                                    fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.inkSoft)),
                                          ]),
                                        ),
                                      ),
                                      if (!isAlt) ...[
                                        const SizedBox(width: 8),
                                        _KeepChip(kept: kept, onTap: _toggleKeep),
                                      ],
                                    ]),
                                    const SizedBox(height: 7),
                                    // The stylist's remark — italic serif so it reads as
                                    // their voice; tap to expand if it doesn't fit.
                                    GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () => setState(() => _noteExpanded = !_noteExpanded),
                                      child: Text('“$line”',
                                          maxLines: _noteExpanded ? null : 2,
                                          overflow: _noteExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontStyle: FontStyle.italic,
                                              fontWeight: FontWeight.w500,
                                              fontSize: 14.5,
                                              height: 1.3,
                                              color: AppColors.inkSoft)),
                                    ),
                                    // Real-inventory match for this suggestion: brand,
                                    // price and an immediate Buy — the review flow's
                                    // monetization surface.
                                    if (kCommerce && isAlt && alt!.shop != null) ...[
                                      const SizedBox(height: 8),
                                      Row(children: [
                                        Expanded(
                                          child: Text(
                                              '${(alt.shop!['brand'] ?? '').toString().toUpperCase()} · ${alt.shop!['name'] ?? ''}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontSize: 11.5, fontWeight: FontWeight.w800,
                                                  letterSpacing: 0.4, color: AppColors.ink)),
                                        ),
                                        if (kCommerce) ...[
                                          const SizedBox(width: 8),
                                          Text(
                                              '${alt.shop!['currency'] ?? 'USD'} ${alt.shop!['price'] ?? ''}',
                                              style: const TextStyle(
                                                  fontSize: 12.5, fontWeight: FontWeight.w800,
                                                  color: AppColors.signature)),
                                          const SizedBox(width: 10),
                                          GestureDetector(
                                            onTap: () => launchUrl(
                                                Uri.parse((alt.shop!['buyUrl'] ?? '').toString()),
                                                mode: LaunchMode.externalApplication),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
                                              decoration: BoxDecoration(
                                                  color: AppColors.ink,
                                                  borderRadius: BorderRadius.circular(999)),
                                              child: const Text('Buy',
                                                  style: TextStyle(
                                                      color: Colors.white, fontSize: 11.5,
                                                      fontWeight: FontWeight.w800)),
                                            ),
                                          ),
                                        ],
                                      ]),
                                    ],
                                    // Comparative styling cue: previewing an item while
                                    // other zones are locked → say what it's judged against.
                                    if (isAlt && _locked.isNotEmpty && !_locked.contains(_sel)) ...[
                                      const SizedBox(height: 4),
                                      Row(mainAxisSize: MainAxisSize.min, children: [
                                        const Icon(Icons.lock, size: 11, color: AppColors.muted),
                                        const SizedBox(width: 4),
                                        Flexible(
                                          child: Text(
                                              'editor.anchoredTo'.tr(args: [
                                                _locked.map((i) => slots[i].item).join(', ')
                                              ]),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontSize: 11.5, color: AppColors.muted)),
                                        ),
                                      ]),
                                    ],
                                  ],
                                );
                              }),
                              // LOOKS-FIRST: полные образы вместо по-вещевой
                              // рутины — тап по карточке = один рендер лука.
                              if (_kLooksFirst && _lookBoardsPending && _lookCards.isEmpty) ...[
                                const SizedBox(height: 12),
                                SizedBox(
                                  height: 148,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    physics: const NeverScrollableScrollPhysics(),
                                    itemCount: 4,
                                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                                    itemBuilder: (_, _) => Container(
                                      width: 118,
                                      decoration: BoxDecoration(
                                        color: AppColors.surface,
                                        borderRadius: BorderRadius.circular(AppRadius.control),
                                      ),
                                      child: const Center(
                                        child: SizedBox(width: 16, height: 16,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.muted)),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                              if (_kLooksFirst && _lookCards.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                SizedBox(
                                  height: 148,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    physics: const BouncingScrollPhysics(),
                                    padding: const EdgeInsets.only(right: 28),
                                    itemCount: _lookCards.length,
                                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                                    itemBuilder: (_, i) {
                                      final (ids, title, boardUrl) = _lookCards[i];
                                      return GestureDetector(
                                        onTap: _lookBusy ? null : () => _wearLook(ids),
                                        child: Container(
                                          width: 118,
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: BorderRadius.circular(AppRadius.control),
                                            border: Border.all(color: AppColors.line),
                                          ),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.stretch,
                                            children: [
                                              Expanded(
                                                child: ClipRRect(
                                                  borderRadius: const BorderRadius.vertical(
                                                      top: Radius.circular(AppRadius.control)),
                                                  child: Image.network(boardUrl, fit: BoxFit.cover,
                                                      loadingBuilder: (_, child, pr) => pr == null
                                                          ? child
                                                          : const ColoredBox(color: AppColors.surface)),
                                                ),
                                              ),
                                              Padding(
                                                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                                                child: Row(children: [
                                                  if (_lookRenders[ids.join('+')] != null) ...[
                                                    const Icon(Icons.check_circle,
                                                        size: 11, color: AppColors.signature),
                                                    const SizedBox(width: 3),
                                                  ],
                                                  Expanded(child: Text(
                                                  _lookBusyKey == ids.join('+') ? 'Rendering…' : title,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                      fontSize: 10.5, fontWeight: FontWeight.w700),
                                                )),
                                                ]),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                              if (!(_kLooksFirst && (_lookCards.isNotEmpty || _lookBoardsPending))) ...[
                              const SizedBox(height: 12),
                              // Slot rail.
                              SizedBox(
                                height: 38,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  physics: const BouncingScrollPhysics(),
                                  itemCount: slots.length,
                                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                                  itemBuilder: (_, i) {
                                    final on = i == _sel;
                                    final locked = _locked.contains(i);
                                    final decided = locked || _picked.containsKey(i); // shows a tick in the rail
                                    return GestureDetector(
                                      onTap: () => _pickSlot(i),
                                      onLongPress: () {
                                        HapticFeedback.mediumImpact();
                                        setState(() => locked ? _locked.remove(i) : _locked.add(i));
                                        _mirrorLocks();
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 14),
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: on ? AppColors.ink : Colors.white,
                                          borderRadius: BorderRadius.circular(999),
                                          border: Border.all(
                                              color: on ? AppColors.ink : const Color(0xFFE6E3DC)),
                                          boxShadow: on
                                              ? null
                                              : const [
                                                  BoxShadow(
                                                      color: Color(0x08000000),
                                                      blurRadius: 10,
                                                      offset: Offset(0, 3)),
                                                ],
                                        ),
                                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                                          // Anchor state first: a locked zone shows the padlock
                                          // (long-press toggles it); a worn pick shows the tick.
                                          if (locked) ...[
                                            Icon(Icons.lock, size: 12, color: on ? Colors.white70 : AppColors.muted),
                                            const SizedBox(width: 5),
                                          ] else if (decided) ...[
                                            const Icon(Icons.check_circle, size: 12, color: AppColors.signature),
                                            const SizedBox(width: 5),
                                          ],
                                          Text(_pretty(slots[i].slot),
                                              style: TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 13,
                                                  color: on ? Colors.white : AppColors.ink)),
                                        ]),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              // Fit strip — how the top SITS (tuck, sleeves,
                              // layer). Lives with the editing tools, not over
                              // the photo; Top tab only.
                              if (_kFitControls && slots[_sel].slot == 'top') ...[
                                const SizedBox(height: 10),
                                _fitStrip(),
                              ],
                              const SizedBox(height: 12),
                              // Alternatives strip — a native swipe carousel (no
                              // arrow buttons on mobile; the trailing right inset
                              // lets the next card peek past the sheet padding).
                              SizedBox(
                                height: 74,
                                child: Builder(builder: (_) {
                                  // Strict category constraint: outfit-set
                                  // descriptions (collage thumbs) never
                                  // reach a single-category rail.
                                  final visible = _visibleAlts();
                                  return ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    physics: const BouncingScrollPhysics(),
                                    padding: const EdgeInsets.only(right: 28),
                                    // NOW + filtered alts (or 1 placeholder) + refresh tile.
                                    itemCount: 1 + (visible.isEmpty ? 1 : visible.length) + 1,
                                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                                    itemBuilder: (_, i) {
                                      if (i == 0) return _thumb(0); // NOW
                                      if (visible.isEmpty) {
                                        return i == 1 ? _emptyRailNote() : _refreshTile();
                                      }
                                      if (i <= visible.length) return _thumb(visible[i - 1]);
                                      return _refreshTile();
                                    },
                                  );
                                }),
                              ),
                              const SizedBox(height: 12),
                              // Whole-look auto-styler lives at the very bottom so it
                              // doesn't crowd the per-piece controls.
                              _StyleBestButton(busy: false, onTap: _styleBest),
                              ],
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Whole-look auto-styler — a clear, full-width action at the top of the controls
/// (SDD §14.15). Applies the stylist's best picks across the look in one tap.
class _StyleBestButton extends StatelessWidget {
  const _StyleBestButton({required this.busy, required this.onTap});
  final bool busy;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.ink,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
            busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.auto_awesome, size: 19, color: AppColors.signature),
            const SizedBox(width: 9),
            Text('editor.styleWholeLook'.tr(),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15, letterSpacing: -0.2)),
          ]),
        ),
      ),
    );
  }
}

/// Non-blocking wait state for the avatar: a soft shimmer sweep over the held
/// frame + the signature bobbing hanger. No heavy veil — the person stays
/// readable and the whole screen stays interactive while the render bakes.
class _AvatarShimmer extends StatelessWidget {
  const _AvatarShimmer({this.item, this.overImage = false, this.backdrop, this.zone, this.showTimer = true});
  // The gamified scanner (scan line + forecast capsule + the garment being
  // dressed) — see widgets/style_scanner.dart.
  final Uint8List? item;
  final bool overImage; // true = the carry-in plays OVER the visible avatar
  final Uint8List? backdrop; // blurred selfie behind the first-run scene
  final String? zone; // body zone the carried garment travels toward
  final bool showTimer; // vertical timer: ON while picking (swap), OFF on load
  @override
  Widget build(BuildContext context) =>
      StyleScanner(item: item, overImage: overImage, backdrop: backdrop, zone: zone, showTimer: showTimer);
}

/// Typography-only "Style Score" — no stars (too generic for the editorial
/// register). 0–100 scale + a short editorial badge, e.g. `SCORE 82/100 · SOLID
/// CORE`. Mapping: the critique scores 1–10 → ×10 here. (If a backend ever
/// returns 1–5 floats, map with `(score * 20).round().clamp(0, 100)`.)
class _StyleScore extends StatelessWidget {
  const _StyleScore({required this.score100});
  final int score100; // 0–100

  static String _badge(int s) => s >= 90
      ? 'STANDOUT'
      : s >= 75
          ? 'SOLID CORE'
          : s >= 60
              ? 'WORKABLE'
              : s >= 40
                  ? 'OFF BALANCE'
                  : 'REWORK IT';

  @override
  Widget build(BuildContext context) {
    final s = score100.clamp(0, 100);
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
      const Text('SCORE',
          style: TextStyle(color: AppColors.muted, fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
      const SizedBox(width: 7),
      Text('$s',
          style: const TextStyle(color: AppColors.ink, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.6, height: 1)),
      const Text('/100',
          style: TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w600)),
      const SizedBox(width: 8),
      const Text('·', style: TextStyle(color: AppColors.muted, fontSize: 12)),
      const SizedBox(width: 8),
      Text(_badge(s),
          style: const TextStyle(color: AppColors.ink, fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
    ]);
  }
}

/// "Wear" — the primary commit action, as a prominent extended FAB floated over
/// the avatar's bottom-right corner (best-practice placement + size). Cobalt
/// pill, icon + label, soft elevation.
class _WearFab extends StatelessWidget {
  const _WearFab({required this.busy, required this.onTap, this.label});
  final bool busy;
  final VoidCallback onTap;
  final String? label; // null → the classic "Wear this"
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: AppColors.signature,
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
                color: AppColors.signature.withValues(alpha: 0.4),
                blurRadius: 18, offset: const Offset(0, 6)),
            const BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 3)),
          ],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
              : const Icon(Icons.checkroom_rounded, size: 22, color: Colors.white),
          const SizedBox(width: 8),
          Text(busy ? 'Wearing…' : (label ?? 'Wear this'),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
        ]),
      ),
    );
  }
}

/// Per-slot "Keep" toggle — locks your choice for that slot; it's applied on Save.
class _KeepChip extends StatelessWidget {
  const _KeepChip({required this.kept, required this.onTap});
  final bool kept;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          // Soft cobalt-tinted fill — enough visual weight to hold its own next
          // to the Style Score (the old hairline outline vanished beside it).
          color: kept ? AppColors.signature : const Color(0xFFEBF0FE),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(kept ? Icons.check : Icons.add, size: 15, color: kept ? Colors.white : AppColors.signature),
          const SizedBox(width: 4),
          Text(kept ? 'Kept' : 'Keep',
              style: TextStyle(
                  color: kept ? Colors.white : AppColors.ink, fontWeight: FontWeight.w800, fontSize: 12)),
        ]),
      ),
    );
  }
}

/// Hairline pins from each margin card to its body zone — the magazine
/// spec-sheet read (dot on the zone, thin line to the card).
class _CollagePins extends CustomPainter {
  const _CollagePins(this.links);
  final List<(Offset, Offset)> links;
  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = const Color(0x4D000000)
      ..strokeWidth = 1;
    final dot = Paint()..color = AppColors.ink;
    final ring = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    for (final (a, b) in links) {
      canvas.drawLine(a, b, line);
      canvas.drawCircle(b, 3.2, dot);
      canvas.drawCircle(b, 3.2, ring);
    }
  }

  @override
  bool shouldRepaint(_CollagePins old) => old.links != links;
}
