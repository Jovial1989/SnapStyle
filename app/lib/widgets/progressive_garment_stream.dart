import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Latent streaming: the render "crystallizes" out of blur instead of appearing.
///
/// The GPU worker decodes its latents through a tiny autoencoder every few
/// denoise steps and broadcasts 128×192 JPEG previews on Realtime channel
/// `vton:<renderId>` — the id fix-dispatch already returned, so subscribing
/// costs no new API. This widget cross-fades each incoming preview over the
/// last and melts a blur away as the step count climbs: 20 logical px at the
/// first preview down to ~2 px at the last, so the image sharpens INTO focus
/// rather than flickering through drafts. Midjourney's trick, one Streams
/// subscription deep.
///
/// Silence is a valid stream. If no preview ever arrives (engine cold, TAESD
/// missing, channel dropped) the widget just keeps showing [placeholder] —
/// the render itself still lands through the normal polling path, so this
/// layer is pure garnish and must never gate anything.
/// Debug chip: shows LIVE + received-frame count over the stream. Proof of the
/// subscription's health visible ON the phone — "no chip" = the widget never
/// mounted, "LIVE 0" = joined but nothing arrived, "LIVE n" = frames flowing.
/// Turn off together with the pod's OSD before any demo.
const bool kStreamDebug = true;

class ProgressiveGarmentStream extends StatefulWidget {
  const ProgressiveGarmentStream({
    super.key,
    required this.renderId,
    this.placeholder,
    this.fit = BoxFit.cover,
  });

  /// The fix_renders row id — the broadcast channel is `vton:<renderId>`.
  final String renderId;

  /// Shown until the first preview arrives (and forever, if none does).
  final Widget? placeholder;

  final BoxFit fit;

  @override
  State<ProgressiveGarmentStream> createState() =>
      _ProgressiveGarmentStreamState();
}

class _ProgressiveGarmentStreamState extends State<ProgressiveGarmentStream> {
  RealtimeChannel? _channel;
  Uint8List? _frame;
  int _received = 0;
  String _sub = '…';
  int _step = 0;
  int _layer = 0;
  int _layers = 1;
  static const _lastStep = 15; // the worker emits at 5/10/15 of 20

  @override
  void initState() {
    super.initState();
    _channel = Supabase.instance.client
        .channel('vton:${widget.renderId}')
        .onBroadcast(
          event: 'preview',
          callback: (payload) {
            // COUNT ARRIVAL BEFORE PARSING. The chip exists to separate "nothing
            // arrived" from "arrived in a shape I did not expect", and counting
            // after the parse collapsed the two: the Dart SDK hands broadcast
            // messages WRAPPED ({event, type, payload: {…}}) where supabase-js
            // hands the inner payload directly — verified with a JS subscriber
            // that received what the phone reported as silence. Nine frames sent,
            // zero counted, all nine discarded by a shape check one line above
            // the counter.
            if (mounted && kStreamDebug) setState(() => _received++);
            final inner = (payload['payload'] is Map)
                ? Map<String, dynamic>.from(payload['payload'] as Map)
                : payload;
            final jpg = inner['jpg'];
            if (jpg is! String) return;
            Uint8List bytes;
            try {
              bytes = base64Decode(jpg);
            } catch (_) {
              return; // a torn frame is not worth a crash
            }
            if (!mounted) return;
            setState(() {
              _frame = bytes;
              _step = (inner['step'] as num?)?.toInt() ?? _step;
              _layer = (inner['layer'] as num?)?.toInt() ?? _layer;
              _layers = (inner['layers'] as num?)?.toInt() ?? _layers;
            });
          },
        )
      ..subscribe((status, [_]) {
        if (mounted && kStreamDebug) setState(() => _sub = status.name);
      });
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }

  /// 20 px of blur at the first preview, ~2 px at the last, ACROSS ALL LAYERS:
  /// a three-garment job restarts its step counter per layer, and resetting the
  /// blur with it would pulse sharp→soft three times. Progress here is the
  /// job's, not the layer's.
  double get _blur {
    final done = (_layer + _step / _lastStep).clamp(0.0, _layers.toDouble());
    final t = (done / _layers).clamp(0.0, 1.0);
    return ui.lerpDouble(20.0, 2.0, t)!;
  }

  Widget _chip() => Positioned(
        top: 8, right: 8,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              color: const Color(0xB3000000),
              borderRadius: BorderRadius.circular(6)),
          child: Text('LIVE $_received · $_sub',
              style: const TextStyle(
                  color: Color(0xFF7CFF7C), fontSize: 10,
                  fontWeight: FontWeight.w700)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    if (frame == null) {
      return Stack(fit: StackFit.expand, children: [
        widget.placeholder ?? const SizedBox.expand(),
        if (kStreamDebug) _chip(),
      ]);
    }
    return _withChip(ClipRect(
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
            sigmaX: _blur, sigmaY: _blur, tileMode: TileMode.decal),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 360),
          switchInCurve: Curves.easeOut,
          child: Image.memory(
            frame,
            key: ValueKey(_frame.hashCode),
            fit: widget.fit,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low, // 128px source: bilinear, not cubic
          ),
        ),
      ),
    ));
  }

  Widget _withChip(Widget body) => Stack(fit: StackFit.expand, children: [
        body,
        if (kStreamDebug) _chip(),
      ]);
}
