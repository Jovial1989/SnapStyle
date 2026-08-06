import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_flutter/webview_flutter.dart';

/// Transparent WebView host for the vanilla Three.js try-on viewer.
///
/// The Flutter side owns the outfit state; the scene is a dumb renderer driven
/// through one bridge call, `window.updateOutfit(top, bottom)`.
///
/// ── Why a loopback server instead of `loadFlutterAsset` ────────────────────
/// WKWebView refuses ES-module imports over `file://` (CORS on a null origin),
/// so `import * as THREE from './vendor/three.module.js'` silently yields a
/// blank canvas on iOS — the page loads, nothing renders, no error in Dart.
/// Serving the same assets from `http://127.0.0.1:<port>` fixes it, keeps the
/// page fully offline, and makes relative paths behave like on the web.
/// `AssetSource.flutterAsset` is kept for pages that use a single classic
/// `<script>` with no module imports.
enum AssetSource { loopbackServer, flutterAsset }

class Avatar3DWidget extends StatefulWidget {
  const Avatar3DWidget({
    super.key,
    this.topUrl,
    this.bottomUrl,
    this.assetDir = 'assets/3d_engine',
    this.entry = 'index.html',
    this.source = AssetSource.loopbackServer,
    this.backdrop = const Color(0xFFF6F5F2),
    this.onReady,
  });

  /// Garment model URLs, relative to the page (e.g. `models/tee.glb`).
  /// `null` means the slot is empty — the scene removes whatever it wore.
  final String? topUrl;
  final String? bottomUrl;

  /// Flutter asset directory holding index.html and its resources.
  final String assetDir;
  final String entry;
  final AssetSource source;

  /// Painted behind the transparent canvas so the 3D sits on the app's own
  /// background — no second, slightly-different colour behind an iframe.
  final Color backdrop;

  final VoidCallback? onReady;

  @override
  State<Avatar3DWidget> createState() => _Avatar3DWidgetState();
}

class _Avatar3DWidgetState extends State<Avatar3DWidget> {
  WebViewController? _controller;
  HttpServer? _server;
  bool _pageReady = false;

  /// Commands issued before the page finished loading. Without this queue the
  /// first outfit (set in the parent's initState) is silently dropped.
  final List<String> _pending = <String>[];

  static const _mime = <String, String>{
    'html': 'text/html; charset=utf-8',
    'js': 'application/javascript',
    'css': 'text/css',
    'glb': 'model/gltf-binary',
    'gltf': 'model/gltf+json',
    'bin': 'application/octet-stream',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'webp': 'image/webp',
    'hdr': 'image/vnd.radiance',
    'json': 'application/json',
  };

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Fully transparent: the platform view stops painting its own white
      // page background, so the Flutter backdrop shows through the canvas.
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel('SceneBridge', onMessageReceived: _onSceneMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _onPageFinished(),
          onWebResourceError: (e) =>
              debugPrint('[Avatar3D] ${e.errorCode} ${e.description}'),
          // The scene is local; block anything trying to navigate away.
          onNavigationRequest: (req) => req.url.startsWith('http://127.0.0.1') ||
                  req.url.startsWith('file://')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
        ),
      );

    if (widget.source == AssetSource.flutterAsset) {
      await controller.loadFlutterAsset('${widget.assetDir}/${widget.entry}');
    } else {
      final server = await _startAssetServer();
      if (!mounted) {
        await server.close(force: true);
        return;
      }
      _server = server;
      await controller
          .loadRequest(Uri.parse('http://127.0.0.1:${server.port}/${widget.entry}'));
    }

    if (!mounted) return;
    setState(() => _controller = controller);
  }

  /// Serves the bundled asset directory on loopback. Bound to 127.0.0.1 with an
  /// ephemeral port: nothing outside the device can reach it.
  Future<HttpServer> _startAssetServer() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path == '/' ? '/${widget.entry}' : req.uri.path;
      try {
        final data = await rootBundle.load('${widget.assetDir}$path');
        final ext = path.split('.').last.toLowerCase();
        req.response.headers.contentType =
            ContentType.parse(_mime[ext] ?? 'application/octet-stream');
        req.response.headers.set('Cache-Control', 'no-store');
        req.response.add(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      } catch (_) {
        req.response.statusCode = HttpStatus.notFound;
      }
      await req.response.close();
    });
    return server;
  }

  void _onPageFinished() {
    _pageReady = true;
    // Flush whatever the parent asked for while the page was still loading.
    for (final js in _pending) {
      _controller?.runJavaScript(js);
    }
    _pending.clear();
    // Push the current outfit even if nothing queued (first paint).
    _pushOutfit();
  }

  void _onSceneMessage(JavaScriptMessage message) {
    // The scene reports 'ready' once the body and environment are decoded, so
    // the loader can hide on real readiness rather than on page load.
    if (message.message == 'ready' && mounted) {
      widget.onReady?.call();
      setState(() {});
    } else {
      debugPrint('[Avatar3D] scene: ${message.message}');
    }
  }

  @override
  void didUpdateWidget(covariant Avatar3DWidget old) {
    super.didUpdateWidget(old);
    if (old.topUrl != widget.topUrl || old.bottomUrl != widget.bottomUrl) {
      _pushOutfit();
    }
  }

  /// One bridge call per outfit change. Arguments go through jsonEncode so a
  /// URL containing a quote or backslash cannot break out of the expression —
  /// string interpolation here would be an injection waiting to happen.
  void _pushOutfit() {
    final js = 'window.updateOutfit('
        '${jsonEncode(widget.topUrl)},'
        '${jsonEncode(widget.bottomUrl)});';
    if (_pageReady && _controller != null) {
      _controller!.runJavaScript(js);
    } else {
      _pending
        ..clear() // only the latest state matters
        ..add(js);
    }
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return ColoredBox(
      color: widget.backdrop,
      child: controller == null
          ? const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : WebViewWidget(controller: controller),
    );
  }
}
