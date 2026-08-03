import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../providers.dart';
import '../services/api_client.dart';
import '../theme.dart';

/// Atelier — the two-tier dressing flow:
///   TIER 1 (this WebView): the user's photo + pose-anchored catalog overlays.
///     Instant browsing, zero cost per swap. Served from a loopback HTTP
///     server (WKWebView refuses ES modules over file://; 127.0.0.1 works and
///     stays offline — no CDN).
///   TIER 2 (the ✦ Make it real button in the page): the assembled look goes
///     over the LooktokBridge channel to generate-vton — one photoreal render
///     of the whole outfit, saved server-side into My Looks.
///
/// The page's bundled user_photo.jpg is a placeholder: the server intercepts
/// that path and serves the OWNER's real body photo instead, so likeness
/// comes from data, not from shipped assets.
class Atelier3dScreen extends ConsumerStatefulWidget {
  const Atelier3dScreen({super.key});

  @override
  ConsumerState<Atelier3dScreen> createState() => _Atelier3dScreenState();
}

class _Atelier3dScreenState extends ConsumerState<Atelier3dScreen> {
  HttpServer? _server;
  WebViewController? _web;
  Uint8List? _userPhoto; // the profile body photo, served over the placeholder
  bool _rendering = false;

  static const _types = {
    'html': 'text/html; charset=utf-8',
    'js': 'application/javascript',
    'glb': 'model/gltf-binary',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'hdr': 'application/octet-stream',
    'svg': 'image/svg+xml',
    'json': 'application/json',
  };

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    // Best-effort preload of the real photo — the bundled placeholder keeps
    // the atelier usable when the profile has none yet.
    try {
      final api = ref.read(looktokApiProvider);
      final path = await api.bodyPhotoPath();
      if (path != null) {
        // Canonical avatar (same person, neutral grey basics) beats the raw
        // photo as an overlay base: no double-dressing against street clothes.
        String url;
        try {
          url = await api.bodyPhotoUrl('$path.avatar.png');
        } catch (_) {
          url = await api.bodyPhotoUrl(path);
        }
        final res = await HttpClient().getUrl(Uri.parse(url)).then((r) => r.close());
        final bytes = await res.fold<BytesBuilder>(BytesBuilder(), (b, c) => b..add(c));
        _userPhoto = bytes.takeBytes();
      }
    } catch (_) {/* placeholder photo it is */}

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path == '/' ? '/3d/index.html' : req.uri.path;
      try {
        // The one dynamic asset: the user's own photo over the placeholder.
        if (path.endsWith('/models/user_photo.jpg') && _userPhoto != null) {
          req.response.headers.contentType = ContentType.parse('image/jpeg');
          req.response.add(_userPhoto!);
        } else {
          final data = await rootBundle.load('assets/atelier$path');
          final ext = path.split('.').last;
          req.response.headers.contentType =
              ContentType.parse(_types[ext] ?? 'application/octet-stream');
          req.response.add(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        }
      } catch (_) {
        req.response.statusCode = HttpStatus.notFound;
      }
      await req.response.close();
    });

    final web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFF6F5F2))
      ..addJavaScriptChannel('LooktokBridge', onMessageReceived: (msg) {
        _onBridge(msg.message);
      })
      ..loadRequest(Uri.parse('http://127.0.0.1:${server.port}/3d/index.html'));
    if (!mounted) {
      server.close(force: true);
      return;
    }
    setState(() {
      _server = server;
      _web = web;
    });
  }

  /// TIER 2 trigger from the page: {type:'generate-vton', garmentId?/garmentIds?}.
  Future<void> _onBridge(String raw) async {
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (payload['type'] != 'generate-vton' || _rendering) return;
    setState(() => _rendering = true);
    try {
      final api = ref.read(looktokApiProvider);
      final ids = (payload['garmentIds'] as List?)?.cast<String>();
      final r = await api.generateVton(
        garmentId: payload['garmentId'] as String?,
        category: payload['category'] as String?,
        garmentIds: ids,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          insetPadding: const EdgeInsets.all(18),
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.card)),
              child: Image.network(r.url, fit: BoxFit.contain,
                  loadingBuilder: (_, child, p) => p == null
                      ? child
                      : const Padding(
                          padding: EdgeInsets.all(60),
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.ink))),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                (ids?.length ?? 1) > 1 ? 'Saved to My Looks' : 'Your photoreal look',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ]),
        ),
      );
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Could not render the look — try again.')));
      }
    } finally {
      _rendering = false;
      if (mounted) setState(() {});
      // Give the page its button back regardless of outcome.
      _web?.runJavaScript('window.vtonDone && window.vtonDone()');
    }
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F5F2),
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Atelier'),
      ),
      body: _web == null
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : WebViewWidget(controller: _web!),
    );
  }
}
