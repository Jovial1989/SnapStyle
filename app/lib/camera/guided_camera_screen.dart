import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'confirm_photo_screen.dart';
import 'silhouette_overlay.dart';

/// Config for a guided capture: which silhouette + which hints.
class GuidedCaptureConfig {
  final String title;
  final SilhouetteKind silhouette;
  final List<String> hints;
  final CameraLensDirection lens;

  const GuidedCaptureConfig({
    required this.title,
    required this.silhouette,
    required this.hints,
    this.lens = CameraLensDirection.back,
  });

  static const body = GuidedCaptureConfig(
    title: 'Full-body photo',
    silhouette: SilhouetteKind.fullBody,
    hints: ['Good, even lighting', 'Fit your whole body in frame', 'Arms slightly away from sides'],
  );

  static const outfit = GuidedCaptureConfig(
    title: 'Your outfit',
    silhouette: SilhouetteKind.fullBody,
    hints: ['Show the full outfit', 'Steady, even lighting'],
    lens: CameraLensDirection.back,
  );

  static const mirrorSelfie = GuidedCaptureConfig(
    title: 'Mirror selfie',
    silhouette: SilhouetteKind.fullBody,
    hints: ['Hold the phone steady', 'Show the full outfit'],
    lens: CameraLensDirection.front,
  );
}

/// Custom camera with silhouette overlay + hints. Captures, runs a branded
/// confirm step, and pops the accepted [XFile] (or null if cancelled).
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
              SilhouetteOverlay(kind: widget.config.silhouette),
              _TopBar(title: widget.config.title),
              _BottomCluster(
                hints: widget.config.hints,
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

class _TopBar extends StatelessWidget {
  const _TopBar({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Row(
          children: [
            _Round(icon: Icons.close, onTap: () => Navigator.of(context).pop()),
            Expanded(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(title,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                ),
              ),
            ),
            const SizedBox(width: 44), // balance the close button
          ],
        ),
      ),
    );
  }
}

class _BottomCluster extends StatelessWidget {
  const _BottomCluster({required this.hints, required this.busy, required this.onCapture});
  final List<String> hints;
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
            colors: [Color(0x00000000), Color(0xB3000000)],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...hints.map((h) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check, size: 15, color: Colors.white),
                          const SizedBox(width: 8),
                          Text(h, style: const TextStyle(color: Colors.white, fontSize: 13)),
                        ],
                      ),
                    )),
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: onCapture,
                  child: Container(
                    width: 72,
                    height: 72,
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
