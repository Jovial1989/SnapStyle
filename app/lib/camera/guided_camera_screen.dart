import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'confirm_photo_screen.dart';
import 'silhouette_overlay.dart' show SilhouetteKind;

/// Config for a capture: a single readable instruction + which lens.
class GuidedCaptureConfig {
  final String title;
  final SilhouetteKind silhouette; // retained for callers; overlay no longer drawn
  final String instruction;
  final CameraLensDirection lens;

  const GuidedCaptureConfig({
    required this.title,
    required this.silhouette,
    required this.instruction,
    this.lens = CameraLensDirection.back,
  });

  static const body = GuidedCaptureConfig(
    title: 'Full-body photo',
    silhouette: SilhouetteKind.fullBody,
    instruction:
        'Full body, face visible — no cap, no sunglasses. Wear fitted clothes (a tee with shorts or leggings) so your shape reads clearly.',
  );

  static const outfit = GuidedCaptureConfig(
    title: 'Your outfit',
    silhouette: SilhouetteKind.fullBody,
    instruction: 'Stand full-length, centered in the frame',
    lens: CameraLensDirection.back,
  );

  static const mirrorSelfie = GuidedCaptureConfig(
    title: 'Mirror selfie',
    silhouette: SilhouetteKind.fullBody,
    instruction: 'Show your full outfit in the mirror',
    lens: CameraLensDirection.front,
  );
}

/// A plain camera (no silhouette frame) with one readable instruction at the
/// bottom. Captures, runs a branded confirm step, and pops the accepted [XFile].
class GuidedCameraScreen extends StatefulWidget {
  const GuidedCameraScreen({super.key, required this.config});
  final GuidedCaptureConfig config;

  @override
  State<GuidedCameraScreen> createState() => _GuidedCameraScreenState();
}

class _GuidedCameraScreenState extends State<GuidedCameraScreen> {
  CameraController? _controller;
  Future<void>? _init;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init = _setup();
  }

  Future<void> _setup() async {
    final cameras = await availableCameras();
    final cam = cameras.firstWhere(
      (c) => c.lensDirection == widget.config.lens,
      orElse: () => cameras.first,
    );
    final controller = CameraController(cam, ResolutionPreset.high, enableAudio: false);
    await controller.initialize();
    if (!mounted) return;
    setState(() => _controller = controller);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    final c = _controller;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      final file = await c.takePicture();
      if (!mounted) return;
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => ConfirmPhotoScreen(imagePath: file.path)),
      );
      if (ok == true && mounted) {
        Navigator.of(context).pop(file); // accepted → hand back up
        return;
      }
    } catch (_) {
      // fall through to re-enable shutter
    }
    if (mounted) setState(() => _busy = false); // retake / error
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder(
        future: _init,
        builder: (context, _) {
          if (_controller?.value.isInitialized != true) {
            return const Center(child: CircularProgressIndicator(color: Colors.white));
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _controller!.value.previewSize?.height ?? 1080,
                  height: _controller!.value.previewSize?.width ?? 1920,
                  child: CameraPreview(_controller!),
                ),
              ),
              // Close button only — no frame, no silhouette.
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: _Round(icon: Icons.close, onTap: () => Navigator.of(context).pop()),
                  ),
                ),
              ),
              _BottomCluster(
                instruction: widget.config.instruction,
                busy: _busy,
                onCapture: _capture,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BottomCluster extends StatelessWidget {
  const _BottomCluster({required this.instruction, required this.busy, required this.onCapture});
  final String instruction;
  final bool busy;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x00000000), Color(0xCC000000)],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 40, 24, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // One readable instruction, always visible (best-practice guidance).
                Text(
                  instruction,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
                  ),
                ),
                const SizedBox(height: 22),
                GestureDetector(
                  onTap: onCapture,
                  child: Container(
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      border: Border.all(color: Colors.white24, width: 6),
                    ),
                    child: busy
                        ? const Padding(
                            padding: EdgeInsets.all(22),
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                          )
                        : const Icon(Icons.camera_alt, color: Colors.black),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Round extends StatelessWidget {
  const _Round({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(10), child: Icon(icon, color: Colors.white, size: 22)),
      ),
    );
  }
}
