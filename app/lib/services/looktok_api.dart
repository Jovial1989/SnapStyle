import 'dart:async' show TimeoutException, unawaited;
import 'dart:convert';
import 'dart:io' show SocketException, File, Directory;
import 'dart:typed_data';
import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/analysis.dart';
import '../models/body_profile.dart';
import '../models/profile.dart';
import '../utils/webp_payload.dart';
import 'api_client.dart' show PaywallRequired, ApiException, IdentityMismatchException;
import 'auth.dart' as auth;

/// Cloud integration for all AI flows — Supabase Edge Functions + Storage.
/// Every call carries the user's Supabase JWT (server-authoritative auth + quota);
/// storage uploads land in the user's own folder (RLS-enforced).
///
/// Endpoints (SDD §15): `${SUPABASE_URL}/functions/v1/{analyze,onboarding-profile,generate-look}`.
class LooktokApi {
  LooktokApi({String? functionsBase})
      : functionsBase = functionsBase ??
            '${const String.fromEnvironment('SUPABASE_URL')}/functions/v1';

  final String functionsBase;
  static const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  SupabaseClient get _sb => Supabase.instance.client;
  String get _uid => _sb.auth.currentUser!.id;

  Map<String, String> _headersFor(String? token) => {
        'Content-Type': 'application/json',
        if (_anonKey.isNotEmpty) 'apikey': _anonKey,
        if (token != null) 'Authorization': 'Bearer $token',
      };

  /// A DEAD SESSION IS THE WORST FAILURE MODE: the JWT is still on disk, so the
  /// app looks signed in, but the gateway rejects every call with 401 before
  /// the function even runs — and each screen shows its own generic copy
  /// ("Couldn't read this look"), so the app reads as broken rather than
  /// signed out. Happens whenever the refresh token is revoked (password
  /// change) or the app sat unused past its lifetime.
  /// Recover instead of reporting: refresh, and if that's gone, drop the stale
  /// session and re-establish one. Only if BOTH fail does the user see an
  /// honest "sign in again".
  Future<Map<String, String>> _authedHeaders() async {
    final session = _sb.auth.currentSession;
    final exp = session?.expiresAt;
    final expired = exp != null &&
        DateTime.now().millisecondsSinceEpoch ~/ 1000 >= exp - 60;
    if (session != null && !expired) return _headersFor(session.accessToken);
    return _headersFor(await _recoverSession());
  }

  /// Returns a fresh access token, or throws [ApiException]. Never silently
  /// returns a token we already know is dead.
  Future<String> _recoverSession() async {
    try {
      final s = (await _sb.auth.refreshSession()).session;
      if (s != null) return s.accessToken;
    } catch (_) {/* refresh token revoked or expired → re-establish below */}
    try {
      await auth.signOut();
      await auth.ensureSession();
      final s = _sb.auth.currentSession;
      if (s != null) return s.accessToken;
    } catch (_) {/* fall through to the honest error */}
    throw ApiException('Session expired — please sign in again.');
  }

  // Finite timeout on EVERY Edge Function call: a dead cellular link surfaces
  // as a catchable error (existing handlers show a polite snackbar) instead of
  // an endless spinner. 150s covers the slowest legit call (5-render look set).
  Future<http.Response> _post(String fn, Map<String, dynamic> body) async {
    final payload = jsonEncode(body);
    Future<http.Response> send(Map<String, String> h) => http
        .post(Uri.parse('$functionsBase/$fn'), headers: h, body: payload)
        .timeout(const Duration(seconds: 150));
    final res = await send(await _authedHeaders());
    if (res.statusCode != 401) return res;
    // The token looked valid but the gateway disagreed — recover once, retry.
    return send(_headersFor(await _recoverSession()));
  }

  /// Resilient variant for the interactive VTON calls (try-on renders):
  /// a per-attempt timeout plus retries with exponential backoff on transient
  /// failures. The caller only ever sees a clean, user-facing [ApiException],
  /// never a raw stack or a silent hang.
  ///
  /// TWO THINGS THIS GOT WRONG (03.08) — both cost real money and showed the
  /// user a failure while the server had actually succeeded:
  ///
  /// 1. The 45s budget was BELOW the work. A hosted try-on render takes 45-60s,
  ///    so the client gave up on a call that was about to succeed; every
  ///    `look_renders` row for those taps reads `completed`. Hence [timeout],
  ///    set per call site from what that endpoint really costs.
  /// 2. Retrying a TIMEOUT on a paid render is the expensive mistake. The
  ///    server is still working; a second request starts a SECOND render and
  ///    bills for it. Three attempts meant paying three times for one tap.
  ///    Timeouts now abort immediately; only 5xx and dead sockets retry, since
  ///    those mean no work is in flight.
  Future<http.Response> _postResilient(String fn, Map<String, dynamic> body,
      {int retries = 2, Duration timeout = const Duration(seconds: 45)}) async {
    const transient = {500, 502, 503, 504};
    var delay = const Duration(milliseconds: 700);
    ApiException? last;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final res = await http
            .post(Uri.parse('$functionsBase/$fn'),
                headers: await _authedHeaders(), body: jsonEncode(body))
            .timeout(timeout);
        if (res.statusCode == 401 && attempt < retries) {
          await _recoverSession();
          last = ApiException('Session refreshed — retrying.');
        } else if (transient.contains(res.statusCode) && attempt < retries) {
          last = ApiException('Server is busy — please try again.');
        } else {
          return res; // success, client error, or final transient answer
        }
      } on TimeoutException {
        // Do NOT retry: the render is probably still running server-side.
        throw ApiException('The render is taking too long — try again in a moment.');
      } on SocketException {
        last = ApiException('No internet connection — check your network and retry.');
      } on http.ClientException {
        last = ApiException('Network hiccup — check your connection and retry.');
      }
      if (attempt < retries) {
        await Future.delayed(delay);
        delay *= 3; // 0.7s → 2.1s
      }
    }
    throw last ?? ApiException('Network error — please retry.');
  }

  /// Fire-and-forget: record a "not right — regenerate" render as a NEGATIVE
  /// training pair (person + garment refs + the bad output + reason). Never
  /// throws; the regeneration proceeds regardless of whether this lands.
  Future<void> flagRender({
    required String reason,
    required String instruction,
    required String wrongB64,
    required String wrongMime,
    String? personB64,
    String? personMime,
    List<Map<String, String>> refs = const [],
  }) async {
    try {
      await _post('flag-render', {
        'reason': reason,
        'instruction': instruction,
        'wrong': {'data': wrongB64, 'mimeType': wrongMime},
        if (personB64 != null)
          'person': {'data': personB64, 'mimeType': personMime ?? 'image/jpeg'},
        'refs': refs,
      }).timeout(const Duration(seconds: 20));
    } catch (_) {/* the negative-sample signal is best-effort */}
  }

  /// Upload image bytes to a private bucket under the user's folder.
  /// Returns the storage path to hand to the backend.
  Future<String> uploadPhoto(Uint8List bytes, {String bucket = 'body-photos'}) async {
    final path = '$_uid/${DateTime.now().millisecondsSinceEpoch}.jpg';
    await _sb.storage.from(bucket).uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
        );
    return path;
  }

  /// Flow 1 outfit critique. Authed + quota-gated server-side; throws
  /// [PaywallRequired] on 402 so the caller can present the paywall.
  Future<AnalysisResult> analyze({
    required String base64Image,
    required String mimeType,
    StyleProfile? profile,
    Map<String, dynamic>? bodyOverride, // guest profile (SDD §14.10); null = owner
  }) async {
    final res = await _post('analyze', {
      'image': {'data': base64Image, 'mimeType': mimeType},
      'profile': ?profile?.toApiJson(),
      'subject': ?bodyOverride,
    });
    if (res.statusCode == 402) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      throw PaywallRequired(body['entitlement'] as Map<String, dynamic>?);
    }
    if (res.statusCode != 200) throw ApiException('analysis failed (${res.statusCode})');
    return AnalysisResult.fromResponse(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Onboarding body profiling (synchronous — single Gemini call).
  Future<BodyProfile> onboardingProfile({
    required String photoPath,
    required int heightCm,
    bool ephemeral = false, // guest estimate — don't persist over the owner's profile
  }) async {
    final res = await _post('onboarding-profile',
        {'photoPath': photoPath, 'heightCm': heightCm, if (ephemeral) 'ephemeral': true});
    if (res.statusCode == 422) {
      throw ApiException((jsonDecode(res.body)['note'] ?? 'Photo unusable').toString());
    }
    if (res.statusCode != 200) throw ApiException('Profiling failed (${res.statusCode})');
    return BodyProfile.fromResponse(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Signed URL for the user's default body photo (private `body-photos` bucket).
  Future<String> bodyPhotoUrl(String path, {int expires = 3600}) =>
      _sb.storage.from('body-photos').createSignedUrl(path, expires);

  /// Replace the default body photo (kept in the profile, reused across flows).
  /// Uploads to the user's folder + points `style_profiles.source_photo_path` at it.
  Future<String> setBodyPhoto(Uint8List bytes) async {
    // style_profiles is service-role-write only (clients are SELECT-only under
    // RLS), so persist via the set-body-photo EF after uploading the image.
    final path = await uploadPhoto(bytes); // body-photos bucket, user's folder
    final res = await _post('set-body-photo', {'photoPath': path});
    if (res.statusCode == 422) throw ApiException('Build your body profile first.');
    if (res.statusCode != 200) throw ApiException('Could not update photo (${res.statusCode})');
    return path;
  }

  /// "Vibe Check" — decode a Style DNA from 1–3 reference images, or seed the
  /// smart fallback anchor when skipped (SDD §14.12). Returns the saved DNA.
  Future<Map<String, dynamic>> vibeCheck({
    List<Uint8List> images = const [],
    String? locale,
    bool skip = false,
  }) async {
    final paths = <String>[];
    for (final bytes in images.take(3)) {
      paths.add(await uploadPhoto(bytes)); // body-photos, user's folder
    }
    final res = await _post('vibe-check', {
      if (paths.isNotEmpty) 'imagePaths': paths,
      'locale': ?locale,
      if (skip) 'skip': true,
    });
    if (res.statusCode == 422) throw ApiException('Build your body profile first.');
    if (res.statusCode != 200) throw ApiException('Vibe check failed (${res.statusCode})');
    return ((jsonDecode(res.body)['styleDna']) as Map).cast<String, dynamic>();
  }

  // ── Personalized loader feeds ─────────────────────────────────────────────
  /// Upload the user's own outfit photos (2–10) at onboarding, persist them as
  /// reference looks, and trigger the SILENT backend job that pre-generates a
  /// personal lookbook (shown on the Review loader). No credit burned.
  Future<int> saveReferenceLooks(List<Uint8List> images) async {
    final paths = <String>[];
    for (final bytes in images.take(10)) {
      paths.add(await uploadPhoto(bytes)); // body-photos, user's folder
    }
    if (paths.isEmpty) return 0;
    final res = await _post('save-reference-looks', {'paths': paths});
    if (res.statusCode != 200) throw ApiException('Could not save your looks (${res.statusCode})');
    return ((jsonDecode(res.body)['saved']) as num?)?.toInt() ?? paths.length;
  }

  /// Review-loader feed: the user's silently pre-generated personal looks, or a
  /// trend-targeted fallback when not ready. Items: {url, caption, source}.
  /// Never throws — a dead feed just yields an empty list (loader degrades to ring).
  Future<List<Map<String, dynamic>>> personalFeed() async {
    try {
      final res = await _post('personal-feed', {});
      if (res.statusCode != 200) return const [];
      return (((jsonDecode(res.body)['items']) as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Generate-loader feed: shared archetype "muse" looks matched to [occasion]
  /// (how others dress for it), the user's own aesthetic first. Never throws.
  Future<List<Map<String, dynamic>>> museFeed({String? occasion}) async {
    try {
      final res = await _post('muse-feed', {if (occasion != null) 'occasion': occasion});
      if (res.statusCode != 200) return const [];
      return (((jsonDecode(res.body)['items']) as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
    } catch (_) {
      return const [];
    }
  }

  // ── Fitting Room Copilot ──────────────────────────────────────────────────
  /// Self-hosted rembg service (Fly.io). Overridable at build time:
  /// --dart-define=PREPROCESSOR_URL=… Default matches image-preprocessor/fly.toml.
  static const _preprocessorUrl = String.fromEnvironment('PREPROCESSOR_URL',
      defaultValue: 'https://looktok-preprocessor.fly.dev');

  /// Remove the messy fitting-room background from one mirror selfie. Returns a
  /// clean transparent silhouette — or the ORIGINAL bytes on any failure/
  /// timeout, so the pipeline degrades gracefully while the service is down.
  Future<Uint8List> removeBackground(Uint8List bytes) async {
    try {
      // Shrink the upload to WebP q85 when the platform can encode it —
      // upload time is the dominant latency on cellular.
      final payload = await toWebPPayload(bytes);
      final req = http.MultipartRequest('POST', Uri.parse('$_preprocessorUrl/preprocess'))
        ..files.add(http.MultipartFile.fromBytes('file', payload,
            filename: 'look.${imageExt(payload)}'));
      final res = await req.send().timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) throw Exception('preprocess ${res.statusCode}');
      final out = await res.stream.toBytes();
      return out.isEmpty ? bytes : out;
    } catch (_) {
      return bytes;
    }
  }

  /// Step 1 of the compare pipeline: strip ALL selfies concurrently.
  Future<List<Uint8List>> removeBackgroundBatch(List<Uint8List> images) =>
      Future.wait([for (final b in images) removeBackground(b)]);


  /// Rank 2-4 try-on photos (mirror selfies). Returns looks sorted best-first:
  /// {index, score(0-100), title?, why}. Burns one credit on success.
  Future<List<Map<String, dynamic>>> compareLooks(List<Uint8List> images,
      {String mode = 'looks'}) async {
    // The cleaned silhouettes are heavy PNGs — recompress each to WebP q85
    // (alpha preserved) and label by SNIFFED mime, not assumption. Cuts the
    // JSON payload several-fold on the slowest leg of this call.
    final payloads = await Future.wait([for (final b in images.take(4)) toWebPPayload(b)]);
    final res = await _post('compare-looks', {
      'images': [
        for (final b in payloads) {'data': base64Encode(b), 'mimeType': imageMime(b)},
      ],
      'mode': mode,
    });
    if (res.statusCode == 402) throw PaywallRequired(null);
    if (res.statusCode == 422) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['error'] == 'identity_mismatch') {
        throw IdentityMismatchException([
          for (final i in (body['mismatched'] as List? ?? const [])) (i as num).toInt(),
        ]);
      }
    }
    if (res.statusCode != 200) throw ApiException('Compare failed (${res.statusCode})');
    return (((jsonDecode(res.body)['looks']) as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
  }

  /// FAST recommendations — the no-LLM hot path (hybrid pgvector + pre-computed
  /// tag filters). Calls the `recommend_items` RPC DIRECTLY via PostgREST
  /// (granted to authenticated): one network hop straight into the DB region —
  /// the /recommend Edge Function adds a global-edge detour (~200-400ms) and
  /// exists for non-Supabase consumers. Never throws; empty list = nothing
  /// above the similarity bar.
  Future<List<Map<String, dynamic>>> recommendItems({
    required String anchorId,
    String? category,
    String? occasion,
    String? style,
    int count = 6,
  }) async {
    try {
      final rows = await _sb.rpc('recommend_items', params: {
        'anchor_id': anchorId,
        'match_category': category,
        'match_occasion': occasion,
        'match_style': style,
        'match_count': count,
      });
      return ((rows as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .map((m) => {
                'id': m['id'],
                'brand': m['brand_name'],
                'name': m['name'],
                'category': m['category'],
                'price': m['price'],
                'currency': m['currency'],
                'buyUrl': m['buy_url'],
                'imageUrl': m['image_url'],
                'similarity': m['similarity'],
              })
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// A few shoppable alternatives from the affiliate catalogue (authed read RLS).
  Future<List<Map<String, dynamic>>> affiliateAlternatives({int limit = 3}) async {
    try {
      final rows = await _sb
          .from('affiliate_items')
          .select('brand_name, name, price, currency, buy_url')
          .eq('active', true)
          .limit(limit);
      return (rows as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  /// The user's stored full-body photo path (from onboarding), or null if none.
  /// Journey B restyles this photo for the chosen occasion.
  Future<String?> bodyPhotoPath() async {
    final row = await _sb
        .from('style_profiles')
        .select('source_photo_path')
        .eq('user_id', _uid)
        .maybeSingle();
    final p = row?['source_photo_path'] as String?;
    return (p == null || p.isEmpty) ? null : p;
  }

  /// The user's style profile row, or null if they haven't built one.
  Future<Map<String, dynamic>?> bodyProfile() async {
    final row = await _sb.from('style_profiles').select().eq('user_id', _uid).maybeSingle();
    return row == null ? null : (row as Map).cast<String, dynamic>();
  }

  /// True once a body profile has been built + confirmed (the core-flow gate).
  Future<bool> hasBodyProfile() async {
    final row = await _sb
        .from('style_profiles')
        .select('status, height_cm')
        .eq('user_id', _uid)
        .maybeSingle();
    return row != null && row['status'] == 'ready' && row['height_cm'] != null;
  }

  /// Persist the user's confirmed/corrected body profile (marks it ready).
  Future<void> confirmBodyProfile({String? bodyType, int? heightCm}) async {
    await _sb.from('style_profiles').update({
      'body_type': ?bodyType,
      'height_cm': ?heightCm,
      'status': 'ready',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('user_id', _uid);
  }

  /// Signed URL for an image in the private `generations` bucket (looks + critiques).
  Future<String> lookImageUrl(String path, {int expires = 3600}) =>
      _sb.storage.from('generations').createSignedUrl(path, expires);

  /// Raw bytes of a `generations` image (for reopening a saved critique).
  Future<Uint8List> generationBytes(String path) =>
      _sb.storage.from('generations').download(path);

  /// Signed URL of the user's most recently scanned outfit (for the home
  /// "Frosted Canvas" backdrop). Null if they haven't scanned yet.
  Future<String?> recentScanUrl() async {
    final rows = await _sb
        .from('generations')
        .select('output')
        .eq('user_id', _uid)
        .eq('type', 'critique')
        .eq('status', 'succeeded')
        .order('created_at', ascending: false)
        .limit(1);
    if ((rows as List).isEmpty) return null;
    final p = (rows.first['output']?['image_path'] ?? '').toString();
    return p.isEmpty ? null : lookImageUrl(p);
  }

  /// History: the user's succeeded critiques + looks, newest first.
  Future<List<Map<String, dynamic>>> history({int limit = 60}) async {
    final rows = await _sb
        .from('generations')
        .select('id, type, output, input, created_at')
        .eq('user_id', _uid)
        .eq('status', 'succeeded')
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List).cast<Map<String, dynamic>>();
  }

  /// Generate 3–4 occasion looks on the user's photo to choose from (inspiration
  /// only, never shoppable). Synchronous (~20s), one credit for the set. Returns
  /// the generation id + storage paths; pass each path to [lookImageUrl].
  /// ASYNC fan-out (migration 0010): the dispatcher plans the set, inserts one
  /// `look_renders` row per look and returns their ids IMMEDIATELY (~3-6s) —
  /// no more 30-90s blocking call. Renders run as parallel server-side
  /// workers; watch [lookRenders] for each row flipping pending→completed.
  Future<({String id, List<Map<String, dynamic>> renders})> dispatchLooks(
      {required String photoPath,
      required String event,
      String source = 'inspire',
      Map<String, dynamic>? bodyOverride}) async {
    final res = await _post('generate-look', {
      'photoPath': photoPath,
      'event': event,
      'source': source,
      'subject': ?bodyOverride,
    });
    if (res.statusCode == 402) throw PaywallRequired(null);
    if (res.statusCode == 409) throw ApiException('Your wardrobe is empty — add clothes first.');
    if (res.statusCode != 200 && res.statusCode != 202) {
      throw ApiException('Could not create looks (${res.statusCode})');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final renders = ((body['renders'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    if (renders.isEmpty) throw ApiException('Could not create looks');
    return (id: (body['generationId'] ?? '').toString(), renders: renders);
  }

  /// Live updates for the dispatched render rows (Supabase Realtime, respects
  /// RLS). Emits the current snapshot immediately, then every row change —
  /// the UI flips each skeleton card the moment ITS worker finishes.
  Stream<List<Map<String, dynamic>>> lookRenders(List<String> ids) => _sb
      .from('look_renders')
      .stream(primaryKey: ['id'])
      .inFilter('id', ids)
      .map((rows) => rows.map((r) => r.cast<String, dynamic>()).toList());

  /// Re-run ONE failed render (fan-out fault isolation) — fire-and-forget:
  /// the worker flips the row failed→pending→completed and Realtime carries
  /// every transition to the card; the HTTP response itself is irrelevant.
  Future<void> retryRender(String renderId) async {
    try {
      await _post('render-look', {'render_id': renderId});
    } catch (_) {/* Realtime is the source of truth */}
  }

  /// Grid THUMBNAIL url — Supabase Image Transformation (600px, q80): five
  /// simultaneous raw 2:3 PNGs (~1-2MB each) decoded at full size is exactly
  /// the burst that OOM-kills the Flutter engine on low-RAM devices. The
  /// gallery still loads full-size, but one at a time.
  Future<String> lookThumbUrl(String path, {int expires = 3600}) =>
      _sb.storage.from('generations').createSignedUrl(path, expires,
          transform: const TransformOptions(width: 600, quality: 80));

  /// Preview one recommendation applied to the user's photo (part of a review —
  /// no credit burned). Returns the edited image bytes. ~15s.
  /// [targetZones]/[lockedZones] = the Anchor Items contract: the backend
  /// turns them into hard inpainting boundaries ({"target_zone": "wrist",
  /// "locked_zones": ["top","bottom","shoes"]}) so a watch swap can never
  /// restyle a locked T-shirt. Old servers simply ignore the extra fields.
  /// Returns the render + the backend QA verdict ([applied] == false means
  /// the model returned the outfit essentially unchanged; the CALLER decides
  /// whether to burn time on a decisive re-run with [attempt] = 2).
  Future<({Uint8List bytes, bool applied})> generateFix({
    required String base64Image,
    required String mimeType,
    required String instruction,
    List<String> targetZones = const [],
    List<String> lockedZones = const [],
    List<Uint8List> references = const [], // product shots of the garments to dress
    // A garment that has a REAL product photo passes its URL instead of its
    // bytes: the server hands the renderer a reference and nothing is downloaded,
    // base64'd, POSTed, decoded and re-uploaded. Measured on the same swap:
    // 2081 KB / 16.6s with bytes against 642 KB / 10.3s with the URL.
    List<String> referenceUrls = const [],
    List<String> referenceZones = const [],
    // The SHORT garment name per reference. Slicing `instruction` for this gave
    // the renderer 200 chars of composed-prompt boilerplate with no garment in
    // it, so text conditioning fought the reference image and the old colour won.
    List<String> referenceHints = const [],
    int attempt = 1,
  }) async {
    final refs = <Map<String, String>>[];
    for (final r in references.take(4)) {
      // 768px-capped payloads (references are Gemini renders ≈1300px raw).
      final payload = await toTryonPayload(r);
      refs.add({'data': base64Encode(payload), 'mimeType': imageMime(payload)});
    }
    // Cross-session DISK cache, same fingerprint recipe as the backend's
    // tryon_cache: a hit skips the network entirely (re-entering a look and
    // re-tapping a seen swap paints instantly, even offline).
    final key = sha256
        .convert(utf8.encode([
          // BUMP THIS ON EVERY RENDER-PIPELINE CHANGE. The key covers the inputs,
          // not the engine, so a fix that changes the OUTPUT for identical inputs
          // leaves every stored render valid and stale — measured the hard way: the
          // halo fix was verified on a fresh render while the phone kept serving a
          // pre-fix image from cache, which reads exactly like "it did not work".
          // v16: render from the clean base, never chained. v17: garment-colour
          // fallback bounded by the silhouette. v18: wrist protection keeps skin,
          // not a disc of the old trousers. v19: deterministic seed. v20: upper painted after lower (untucked hem).
          'fix:v58', base64Image, instruction,
          targetZones.join(','), lockedZones.join(','),
          for (final r in refs) r['data']!,
          ...referenceUrls,
          ...referenceZones,
        ].join('|')))
        .toString();
    final cacheFile = await _tryonFile(key);
    if (cacheFile != null && await cacheFile.exists()) {
      try {
        return (bytes: await cacheFile.readAsBytes(), applied: true);
      } catch (_) {/* fall through to the network */}
    }
    final res = await _postResilient('generate-fix', {
      'image': {'data': base64Image, 'mimeType': mimeType},
      'instruction': instruction,
      if (targetZones.isNotEmpty) 'target_zones': targetZones,
      if (lockedZones.isNotEmpty) 'locked_zones': lockedZones,
      if (refs.isNotEmpty) 'references': refs,
      if (referenceUrls.isNotEmpty) 'reference_urls': referenceUrls,
      if (referenceZones.isNotEmpty) 'reference_zones': referenceZones,
      if (referenceHints.isNotEmpty) 'reference_hints': referenceHints,
      if (attempt > 1) 'attempt': attempt,
      // 100s, not 45: the hosted render measures 45-60s, so the old budget
      // failed a call that was about to succeed (every look_renders row for
      // those taps reads `completed`). Drops back toward ~5s once VTON_ENGINE
      // is the self-hosted queue.
    }, timeout: const Duration(seconds: 100));
    if (res.statusCode != 200) throw ApiException('Could not preview the fix (${res.statusCode})');
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final bytes = base64Decode((body['image']?['data'] ?? '').toString());
    final applied = body['applied'] != false;
    // Persist only QA-passed renders — a no-op must never become an instant
    // replay from disk.
    if (cacheFile != null && applied) {
      unawaited(_persistTryon(cacheFile, bytes));
    }
    return (bytes: bytes, applied: applied);
  }

  /// Realtime swap (fast first, right after): answers in <1s with either the
  /// cached render (bytes) or a `fix_renders` row id — watch [fixRender] for
  /// v1 → silent QA replacement → done/failed. Replaces the long-held
  /// generateFix HTTP call in the editor.
  Future<({Uint8List? bytes, Uint8List? bytesTucked, String? renderId})> dispatchFix({
    List<String> referenceUrls = const [],
    List<String> referenceZones = const [],
    List<String> referenceHints = const [],
    // A Storage path for the person INSTEAD of pixels. Our own renders already
    // live in `generations`, so a chained swap re-sends a pointer rather than a
    // couple of megabytes over a mobile uplink.
    String? personPath,
    required String base64Image,
    required String mimeType,
    required String instruction,
    List<String> targetZones = const [],
    List<String> lockedZones = const [],
    List<Uint8List> references = const [],
    // DUAL TUCK: the tucked twin's own instruction + zones. Both states render
    // in one worker job and land on one row — the toggle then swaps locally.
    ({String instruction, List<String> targetZones, List<String> lockedZones})? tucked,
    // FACE IDENTITY ANCHOR: head crop of the client, forwarded to the worker
    // as the last reference image (not part of the cache fingerprint).
    String? identityB64,
  }) async {
    final refs = <Map<String, String>>[];
    for (final r in references.take(4)) {
      // 768px-capped payloads (references are Gemini renders ≈1300px raw).
      final payload = await toTryonPayload(r);
      refs.add({'data': base64Encode(payload), 'mimeType': imageMime(payload)});
    }
    String keyFor(String instr, List<String> tz, List<String> lz) => sha256
        .convert(utf8.encode([
          // personPath REPLACES base64Image when the source is already in
          // Storage, so it has to be in the key — otherwise a chained swap and a
          // pixel-carrying one would collide on the same fingerprint.
          'fix:v58', personPath ?? base64Image, instr,
          tz.join(','), lz.join(','),
          for (final r in refs) r['data']!,
          ...referenceUrls,
          ...referenceZones,
          ...referenceHints,
        ].join('|')))
        .toString();
    final cacheFile =
        await _tryonFile(keyFor(instruction, targetZones, lockedZones));
    final tuckedFile = tucked == null
        ? null
        : await _tryonFile(
            keyFor(tucked.instruction, tucked.targetZones, tucked.lockedZones));
    if (cacheFile != null && await cacheFile.exists()) {
      try {
        final primary = await cacheFile.readAsBytes();
        Uint8List? twin;
        if (tuckedFile != null && await tuckedFile.exists()) {
          twin = await tuckedFile.readAsBytes();
        }
        // Serve the twin too when it exists; a missing twin re-renders on the
        // toggle's first tap (the server cache usually catches it).
        return (bytes: primary, bytesTucked: twin, renderId: null);
      } catch (_) {/* fall through to the network */}
    }
    final res = await _postResilient('fix-dispatch', {
      'image': {'data': base64Image, 'mimeType': mimeType},
      'instruction': instruction,
      if (targetZones.isNotEmpty) 'target_zones': targetZones,
      if (lockedZones.isNotEmpty) 'locked_zones': lockedZones,
      if (refs.isNotEmpty) 'references': refs,
      if (referenceUrls.isNotEmpty) 'reference_urls': referenceUrls,
      if (referenceZones.isNotEmpty) 'reference_zones': referenceZones,
      if (referenceHints.isNotEmpty) 'reference_hints': referenceHints,
      if (personPath != null) 'person_path': personPath,
      if (identityB64 != null)
        'identity': {'data': identityB64, 'mimeType': 'image/jpeg'},
      if (tucked != null)
        'tucked': {
          'instruction': tucked.instruction,
          if (tucked.targetZones.isNotEmpty) 'target_zones': tucked.targetZones,
          if (tucked.lockedZones.isNotEmpty) 'locked_zones': tucked.lockedZones,
        },
    });
    if (res.statusCode != 200 && res.statusCode != 202) {
      throw ApiException('Could not preview the fix (${res.statusCode})');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (body['image']?['data'] ?? '').toString();
    if (data.isNotEmpty) {
      final bytes = base64Decode(data);
      final dataTucked = (body['image_tucked']?['data'] ?? '').toString();
      final twin = dataTucked.isEmpty ? null : base64Decode(dataTucked);
      if (body['cached'] == true) {
        if (cacheFile != null) unawaited(_persistTryon(cacheFile, bytes));
        if (tuckedFile != null && twin != null) {
          unawaited(_persistTryon(tuckedFile, twin));
        }
      }
      return (bytes: bytes, bytesTucked: twin, renderId: null);
    }
    final id = (body['renderId'] ?? '').toString();
    if (id.isEmpty) throw ApiException('Could not preview the fix');
    return (bytes: null, bytesTucked: null, renderId: id);
  }

  /// Live updates for ONE dispatched swap row (Supabase Realtime).
  Stream<Map<String, dynamic>> fixRender(String renderId) => _sb
      .from('fix_renders')
      .stream(primaryKey: ['id'])
      .eq('id', renderId)
      .map((rows) =>
          rows.isEmpty ? <String, dynamic>{} : rows.first.cast<String, dynamic>());

  // ── Local try-on cache plumbing ───────────────────────────────────────────
  static Directory? _tryonDir;
  Future<File?> _tryonFile(String key) async {
    try {
      final base = _tryonDir ??=
          Directory('${(await getApplicationSupportDirectory()).path}/tryon_cache');
      if (!await base.exists()) await base.create(recursive: true);
      return File('${base.path}/$key');
    } catch (_) {
      return null; // no cache dir = no cache, never an error
    }
  }

  Future<void> _persistTryon(File f, Uint8List bytes) async {
    try {
      await f.writeAsBytes(bytes);
      // LRU prune: newest 100 renders (~50-100MB ceiling).
      final files =
          await f.parent.list().where((e) => e is File).cast<File>().toList();
      if (files.length <= 100) return;
      final stamped = <(File, DateTime)>[
        for (final x in files) (x, (await x.stat()).modified),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      for (final (x, _) in stamped.take(files.length - 100)) {
        try {
          await x.delete();
        } catch (_) {}
      }
    } catch (_) {/* best-effort */}
  }

  /// Flat product shot of a garment (no person) for the editor thumbnails.
  Future<Uint8List> generateItem({
    required String base64Image,
    required String mimeType,
    required String instruction,
  }) async {
    final res = await _postResilient('item-image', {
      'image': {'data': base64Image, 'mimeType': mimeType},
      'instruction': instruction,
    });
    if (res.statusCode != 200) throw ApiException('Could not render item (${res.statusCode})');
    final data = (jsonDecode(res.body)['image']?['data'] ?? '').toString();
    return base64Decode(data);
  }

  /// Look boards: up to 4 complete outfits as flat-lay cards, ONE grid render
  /// (~\$0.01/look, cached by garment-id set). Keys = ids.join('+').
  Future<Map<String, String>> lookBoards(List<List<String>> looks,
      {bool auto = false, String? gender}) async {
    try {
      final res = await _post('look-boards', {
        if (!auto) 'looks': [for (final ids in looks) {'garmentIds': ids}],
        if (auto) 'auto': true,
        // gender feeds the server's top-up-to-4 on BOTH paths — without it
        // the unisex-only pool is empty and one matched idea = one card.
        if (gender != null) 'gender': gender,
      });
      if (res.statusCode != 200) return {};
      // URLs, not bytes: the cache-hit path stopped shipping megabytes of
      // base64 (was 10-25s per call) — images stream straight off storage.
      final boards = (jsonDecode(res.body)['boards'] ?? {}) as Map<String, dynamic>;
      return {for (final e in boards.entries) e.key: e.value.toString()};
    } catch (_) {
      return {};
    }
  }

  /// BATCH product shots: one grid render for up to 9 unmatched ideas —
  /// ~$0.004/thumb vs $0.039, one round-trip. Returns instruction → bytes.
  /// Failure returns {} — the lazy per-item path covers every miss.
  Future<Map<String, Uint8List>> generateItemsBatch({
    required String base64Image,
    required String mimeType,
    required List<({String instruction, String slot})> items,
  }) async {
    try {
      final res = await _post('item-images', {
        'image': {'data': base64Image, 'mimeType': mimeType},
        'items': [
          for (final it in items) {'instruction': it.instruction, 'slot': it.slot},
        ],
      });
      if (res.statusCode != 200) return {};
      final images = (jsonDecode(res.body)['images'] ?? {}) as Map<String, dynamic>;
      return {
        for (final e in images.entries)
          e.key: base64Decode(((e.value as Map)['data'] ?? '').toString()),
      };
    } catch (_) {
      return {};
    }
  }

  /// Keep only the chosen variant in "My Looks" — discard the other generated
  /// images and trim the row to the one the user picked.
  Future<void> keepLook(String id,
      {required String keepPath, required List<String> allPaths, String? subjectName}) async {
    final drop = allPaths.where((p) => p != keepPath).toList();
    if (drop.isNotEmpty) await _sb.storage.from('generations').remove(drop);
    final update = <String, dynamic>{
      'output': {'image_path': keepPath, 'image_paths': [keepPath]},
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (subjectName != null) {
      final row = await _sb.from('generations').select('input').eq('id', id).maybeSingle();
      final input = ((row?['input'] ?? {}) as Map).cast<String, dynamic>();
      input['subject'] = subjectName;
      update['input'] = input;
    }
    await _sb.from('generations').update(update).eq('id', id);
  }

  /// Remove a look/review entirely (images + row).
  Future<void> deleteLook(String id, {required List<String> imagePaths}) async {
    final paths = imagePaths.where((p) => p.isNotEmpty).toList();
    if (paths.isNotEmpty) await _sb.storage.from('generations').remove(paths);
    await _sb.from('generations').delete().eq('id', id);
  }

  /// Server-authoritative entitlement for the current user (owner-read RLS).
  /// Shape mirrors the local `ApiClient.entitlement`: { pro, freeRemaining }.
  Future<Map<String, dynamic>> entitlement() async {
    final row = await _sb
        .from('entitlements')
        .select('pro, plan, free_used, bonus_tokens')
        .eq('user_id', _uid)
        .maybeSingle();
    final pro = (row?['pro'] as bool?) ?? false;
    final plan = (row?['plan'] as String?) ?? '';
    final freeUsed = (row?['free_used'] as int?) ?? 0;
    final bonus = (row?['bonus_tokens'] as int?) ?? 0;
    final left = (10 + bonus - freeUsed).clamp(0, 10 + bonus);
    // Premium = the $19.99 tier (fit controls, accessory studio). Pro stays
    // pro — premium perks must never leak down (owner call 22.07).
    return {
      'pro': pro,
      'premium': pro && plan.startsWith('premium'),
      'freeRemaining': left,
    };
  }

  /// Set-level taste feedback: the user walked away from a generated set.
  Future<void> rateLookSet(String generationId, int rating) async {
    await _sb.from('look_feedback').insert({
      'user_id': _uid,
      'generation_id': generationId,
      'rating': rating,
    });
  }

  /// Redeem a promo code (server-authoritative; the EF derives the user from
  /// the JWT). Returns the refreshed entitlement view. Throws [ApiException]
  /// with a user-facing message on invalid/reused codes.
  Future<Map<String, dynamic>> redeemPromoCode(String code) async {
    final res = await _post('redeem-promo-code', {'code': code.trim()});
    final body = jsonDecode(res.body) as Map<String, dynamic>? ?? {};
    if (res.statusCode == 200 && body['ok'] == true) {
      return (body['entitlement'] as Map<String, dynamic>?) ?? {};
    }
    throw ApiException(switch (res.statusCode) {
      404 => 'That code doesn\'t exist — check the spelling.',
      409 => 'This code was already used on your account.',
      401 => 'Please sign in again to redeem a code.',
      _ => 'Couldn\'t redeem the code — try again in a moment.',
    });
  }

  // ── Look editor (P0-1) ────────────────────────────────────────────────────
  /// Detect garment slots on the photo + 2 alternative ideas per slot.
  Future<({List<Map<String, dynamic>> slots, String gender})> outfitSlots(
      String base64Image, String mimeType) async {
    final res = await _post('outfit-slots', {
      'image': {'data': base64Image, 'mimeType': mimeType},
    });
    if (res.statusCode != 200) throw ApiException('Could not read the outfit (${res.statusCode})');
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      slots: ((body['slots'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList(),
      // Keeps thumbs/renders gender-consistent (женские туфли на мужском
      // аватаре came from ideas/thumbs rendered without this signal).
      gender: (body['gender_presentation'] ?? 'neutral').toString(),
    );
  }

  /// Save an edited look into My Looks (owner-insert RLS). [subjectName] tags the
  /// look with a guest's name so history reads "Victoria's look" (SDD §14.10).
  Future<void> saveEditedLook(Uint8List bytes, {String label = 'Edited', String? subjectName}) async {
    final path = '$_uid/${DateTime.now().millisecondsSinceEpoch}-edit.png';
    await _sb.storage.from('generations').uploadBinary(path, bytes,
        fileOptions: const FileOptions(contentType: 'image/png', upsert: true));
    await _sb.from('generations').insert({
      'user_id': _uid,
      'type': 'tryon',
      'status': 'succeeded',
      'provider': 'editor',
      'input': {'occasion': label, 'source': 'editor', 'subject': ?subjectName},
      'output': {'image_path': path, 'image_paths': [path]},
    });
  }

  /// Tag an existing generation (e.g. the auto-saved critique) with a guest name,
  /// so a reopened review also shows whose look it was (SDD §14.10).
  Future<void> nameGeneration(String id, String subjectName) async {
    final row = await _sb.from('generations').select('input').eq('id', id).maybeSingle();
    final input = ((row?['input'] ?? {}) as Map).cast<String, dynamic>();
    input['subject'] = subjectName;
    await _sb.from('generations').update({'input': input}).eq('id', id);
  }

  // ── Digital Wardrobe ──────────────────────────────────────────────────────
  /// Add one clothing item. [category] = the user's explicit intent (top/bottom/
  /// shoes/outerwear/accessory) — the backend isolates exactly that garment
  /// (cheaper + more accurate than guessing). AI still writes the label.
  /// [preIsolated] = the garment was already cut out ON-DEVICE (native engine):
  /// the EF stores it as-is and skips its own isolation hop; pass the raw shot
  /// via [original] so the closet keeps the as-shot photo too.
  Future<Map<String, dynamic>> addWardrobeItem(Uint8List bytes,
      {String? category, bool isWorn = false, bool preIsolated = false, Uint8List? original}) async {
    final res = await _post('wardrobe-add', {
      'image': {'data': base64Encode(bytes), 'mimeType': _mimeOf(bytes)},
      'category': ?category,
      'is_worn': isWorn, // smart router: worn → Gemini; flat/hanger → rembg service
      if (preIsolated) 'pre_isolated': true,
      if (original != null)
        'original': {'data': base64Encode(original), 'mimeType': _mimeOf(original)},
    });
    if (res.statusCode != 200) throw ApiException('Could not add item (${res.statusCode})');
    return ((jsonDecode(res.body)['item']) as Map).cast<String, dynamic>();
  }

  static String _mimeOf(Uint8List b) => imageMime(b); // magic-byte sniffing

  /// The user's wardrobe items, newest first.
  Future<List<Map<String, dynamic>>> wardrobeItems() async {
    final rows = await _sb
        .from('wardrobe_items')
        .select('id, image_path, original_image_path, label, category, created_at')
        .eq('user_id', _uid)
        .order('created_at', ascending: false);
    return (rows as List).cast<Map<String, dynamic>>();
  }

  Future<int> wardrobeCount() async => (await wardrobeItems()).length;

  Future<String> wardrobeImageUrl(String path, {int expires = 3600}) =>
      _sb.storage.from('wardrobe').createSignedUrl(path, expires);

  Future<void> deleteWardrobeItem(String id, {required String imagePath}) async {
    if (imagePath.isNotEmpty) await _sb.storage.from('wardrobe').remove([imagePath]);
    await _sb.from('wardrobe_items').delete().eq('id', id);
  }

  /// Closet category → the VTON engine's slot vocabulary. Null = this garment
  /// type is out of the engine's scope (it renders shoes AS clothing), so the
  /// caller should not offer the photoreal button at all.
  static String? vtonCategory(String closetCategory) => switch (closetCategory) {
        'top' || 'outerwear' => 'upper_body',
        'bottom' => 'lower_body',
        'dress' => 'dresses',
        _ => null,
      };

  /// Photoreal try-on (generate-vton EF → Kolors): dresses the user's profile
  /// body photo in one garment. ~15–20s; burns one free credit on success only.
  /// Returns the PERMANENT public URL — the render is already persisted server-
  /// side (vton bucket + look_generations), nothing to save from the client.
  Future<({String url, String generationId})> generateVton({
    String? garmentId,
    String? category,
    List<String>? garmentIds, // 2+ ids = whole-look commit → saved to My Looks
    String? garmentImageUrl,
  }) async {
    final batch = (garmentIds?.length ?? 0) > 1;
    // A whole-look Gemini render runs 20-40s: the plain 150s transport, no
    // mid-flight retry — a retry would bill a second render.
    final res = batch
        ? await _post('generate-vton', {'garmentIds': garmentIds})
        : await _postResilient('generate-vton', {
            'garmentId': garmentId,
            'category': category,
            'garmentImageUrl': ?garmentImageUrl,
          }, retries: 1, timeout: const Duration(seconds: 100));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200 || j['ok'] != true) {
      throw ApiException(switch (res.statusCode) {
        402 => 'You are out of free renders.',
        409 => 'Add a body photo in your profile first.',
        422 => 'Photoreal try-on works for tops, bottoms and dresses.',
        _ => 'Could not create the photoreal look — try again.',
      });
    }
    return (url: j['url'] as String, generationId: j['generationId'] as String);
  }

  /// BATCH wearing renders: up to 4 looks in ONE gpt-image-1 masked grid on
  /// the canonical avatar — the face is the user's literal pixels (composite),
  /// not a Gemini approximation. ~60s, 1 quota credit for the whole grid.
  /// Failure (no avatar, engine off, error) returns {} — the caller falls
  /// back to per-look Gemini renders.
  Future<Map<String, String>> gridVton(List<List<String>> looks) async {
    try {
      final res = await _post('grid-vton', {
        'looks': [for (final ids in looks) {'garmentIds': ids}],
      });
      if (res.statusCode != 200) return {};
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (j['ok'] != true) return {};
      final renders = (j['renders'] ?? {}) as Map<String, dynamic>;
      return {for (final e in renders.entries) e.key: e.value.toString()};
    } catch (_) {
      return {};
    }
  }

  /// Realtime stream of a single generation row (Flow 2 completion).
  Stream<Map<String, dynamic>> watchGeneration(String generationId) {
    return _sb
        .from('generations')
        .stream(primaryKey: ['id'])
        .eq('id', generationId)
        .map((rows) => rows.isEmpty ? <String, dynamic>{} : rows.first);
  }
}
