import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'premium_loader_overlay.dart';

/// ONE app-level loader for async generation flows, drawn via [OverlayEntry]
/// above everything (routes, app bars, the status bar area). Kills the
/// "two loaders in a row" seam: the overlay goes up when the task starts and
/// comes down ONLY when the destination screen reports it has fully rendered
/// with its image in memory — route transitions happen invisibly beneath it.
///
/// Content: strict full-screen black scene + the staggered premium checklist
/// ([PremiumLoaderOverlay]), optionally over the user's blurred photo.
class GlobalLoaderOverlay {
  GlobalLoaderOverlay._();
  static final GlobalLoaderOverlay instance = GlobalLoaderOverlay._();

  OverlayEntry? _entry;
  Timer? _failsafe;
  Uint8List? _image;
  List<String> _stages = const [];

  bool get isShowing => _entry != null;

  /// Swap the ambient backdrop mid-flight (e.g. the ISOLATED sprite once the
  /// pipeline produces it) — the raw asset never has to be shown "meanwhile".
  void updateImage(Uint8List bytes) {
    _image = bytes;
    _entry?.markNeedsBuild();
  }

  /// Push the overlay above the whole app. Re-showing replaces the current one.
  void show(
    BuildContext context, {
    required List<String> stages,
    Uint8List? image,
    Duration failsafe = const Duration(seconds: 45),
  }) {
    hide();
    _image = image;
    _stages = stages;
    final entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: Material(
            color: Colors.black, // full-bleed: covers notch + home indicator
            // keyed by backdrop identity so updateImage() crossfades cleanly
            child: PremiumLoaderOverlay(
                key: ValueKey(identityHashCode(_image)), stages: _stages, image: _image),
          ),
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(entry);
    _entry = entry;
    // The overlay swallows ALL input — it must never be able to wedge the app.
    // If no one calls hide() (crashed flow, dropped callback), self-dismiss.
    _failsafe = Timer(failsafe, hide);
  }

  void hide() {
    _failsafe?.cancel();
    _failsafe = null;
    _entry?.remove();
    _entry = null;
    _image = null;
  }
}
