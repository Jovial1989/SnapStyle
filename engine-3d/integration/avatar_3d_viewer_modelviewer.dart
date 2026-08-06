import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

/// AAA-grade PBR viewer for a pre-assembled, rigged avatar `.glb`.
///
/// Renderer choice: `<model-viewer>` (via `model_viewer_plus`) over `o3d` /
/// `three_dart`. Google's element is a tuned three.js pipeline — IBL from an
/// HDRI, ACES tone mapping, KHR material extensions, and a real soft contact
/// shadow — all maintained and stable on iOS. `o3d` runs three_dart through
/// flutter_gl: native GL, but immature on iOS, no built-in IBL/shadow plumbing,
/// and you rebuild the whole lighting rig yourself. For "highest possible PBR
/// with the least risk", `<model-viewer>` wins.
///
/// The widget owns its own loading state: the element's default progress bar
/// and interaction prompt are suppressed in CSS, and a Flutter overlay shows
/// until the model's `load` event fires over a JS channel.
class Avatar3DViewer extends StatefulWidget {
  const Avatar3DViewer({
    super.key,
    required this.src,
    this.environmentImage = 'assets/hdri/studio_small_08_1k.hdr',
    this.backdrop = const Color(0xFFF6F5F2),
    this.exposure = 1.05,
    this.shadowIntensity = 1.0,
    this.shadowSoftness = 0.85,
    this.autoRotate = false,
    this.onLoaded,
  });

  /// Asset path or URL of the assembled avatar (body + garments, rigged).
  final String src;

  /// HDRI driving reflections and ambient bounce. Used as the environment
  /// ONLY — never as a skybox, so the studio backdrop stays flat.
  final String environmentImage;

  /// Painted behind the transparent canvas so the 3D blends into the app.
  final Color backdrop;

  final double exposure;
  final double shadowIntensity;
  final double shadowSoftness;
  final bool autoRotate;
  final VoidCallback? onLoaded;

  @override
  State<Avatar3DViewer> createState() => _Avatar3DViewerState();
}

class _Avatar3DViewerState extends State<Avatar3DViewer> {
  bool _loaded = false;

  /// Kill every built-in affordance: the element ships a progress bar, an
  /// "interact" prompt and a default poster, all of which fight a minimalist
  /// studio look. The canvas itself is made transparent so the Flutter
  /// backdrop shows through instead of a second, slightly-off background.
  static const _css = '''
    model-viewer {
      width: 100%;
      height: 100%;
      background-color: transparent;
      --progress-bar-color: transparent;
      --progress-bar-height: 0px;
      --poster-color: transparent;
    }
    model-viewer::part(default-progress-bar) { display: none; }
    model-viewer::part(default-ar-button)     { display: none; }
    body { margin: 0; background: transparent; overflow: hidden; }
  ''';

  /// Report readiness to Flutter. `load` fires once the glTF and its textures
  /// are decoded; the environment is awaited too, otherwise the first frame
  /// pops from unlit to lit.
  static const _js = '''
    const mv = document.querySelector('model-viewer');
    let sent = false;
    const ready = () => {
      if (sent) return;
      sent = true;
      if (window.ModelLoaded) ModelLoaded.postMessage('ready');
    };
    mv.addEventListener('load', () => requestAnimationFrame(ready));
    mv.addEventListener('environment-change', () => { if (mv.loaded) ready(); });
    mv.addEventListener('error', (e) => {
      if (window.ModelLoaded) ModelLoaded.postMessage('error:' + (e.detail?.type ?? 'unknown'));
    });
    // Safety net: never strand the UI behind a spinner.
    setTimeout(ready, 12000);
  ''';

  void _onMessage(JavaScriptMessage m) {
    if (!mounted || _loaded) return;
    if (m.message.startsWith('error:')) {
      debugPrint('[Avatar3DViewer] ${m.message}');
    }
    setState(() => _loaded = true);
    widget.onLoaded?.call();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.backdrop,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ModelViewer(
            src: widget.src,
            alt: 'Your avatar wearing the selected look',

            // ── PBR / lighting ──────────────────────────────────────────
            // environmentImage without skyboxImage = image-based lighting on
            // a clean backdrop: metal and fabric sheen get real reflections,
            // skin picks up soft ambient bounce (the practical stand-in for
            // subsurface scattering in a real-time GL renderer).
            environmentImage: widget.environmentImage,
            exposure: widget.exposure,

            // ── contact shadow: grounds the figure ──────────────────────
            shadowIntensity: widget.shadowIntensity,
            shadowSoftness: widget.shadowSoftness,

            // ── camera: framed on the torso, clamped out of trouble ─────
            cameraControls: true,
            cameraOrbit: '0deg 82deg 3.2m',
            cameraTarget: '0m 1.0m 0m',
            // Pitch stops above the floor plane (95deg) and below straight
            // down (55deg) so the camera never dives under the feet.
            minCameraOrbit: 'auto 55deg auto',
            maxCameraOrbit: 'auto 95deg auto',
            // Zoom bounds keep the near plane outside the mesh: getting inside
            // the body reads as a rendering bug, not a feature.
            minFieldOfView: '22deg',
            maxFieldOfView: '38deg',
            disablePan: true,
            interactionPrompt: InteractionPrompt.none,
            autoRotate: widget.autoRotate,
            autoRotateDelay: 2500,
            rotationPerSecond: '12deg',

            // ── surface / chrome ────────────────────────────────────────
            backgroundColor: Colors.transparent,
            ar: false,
            loading: Loading.eager,
            relatedCss: _css,
            relatedJs: _js,
            javascriptChannels: {
              JavascriptChannel('ModelLoaded', onMessageReceived: _onMessage),
            },
          ),

          // Custom loader — the element's own chrome is disabled above.
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _loaded ? 0 : 1,
              duration: const Duration(milliseconds: 260),
              child: ColoredBox(
                color: widget.backdrop,
                child: const Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF0A0A0A),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
