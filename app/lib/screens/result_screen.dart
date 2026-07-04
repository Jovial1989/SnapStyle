import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../models/analysis.dart';
import '../theme.dart';

/// Editorial-AR result (Clean Canvas): clean photo + floating pins. Tapping a
/// pin shows a small tooltip bubble (pointer) with the core feedback, and the
/// persistent Bottom Rail updates with look suggestions for that pin (SDD §9.4).
class ResultScreen extends StatefulWidget {
  const ResultScreen({super.key, required this.result, required this.imageBytes});
  final AnalysisResult result;
  final Uint8List imageBytes;

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  double? _aspect;
  Hotspot? _active;

  @override
  void initState() {
    super.initState();
    ui.decodeImageFromList(widget.imageBytes, (img) {
      if (mounted) setState(() => _aspect = img.width / img.height);
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    if (!r.analyzable) return _Unusable(note: r.note);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: _aspect == null
                      ? const CircularProgressIndicator(color: Colors.white)
                      : AspectRatio(
                          aspectRatio: _aspect!,
                          child: LayoutBuilder(
                            builder: (context, cons) {
                              final w = cons.maxWidth, h = cons.maxHeight;
                              return Stack(
                                fit: StackFit.expand,
                                children: [
                                  // Tap empty photo → clear selection.
                                  GestureDetector(
                                    onTap: () => setState(() => _active = null),
                                    child: Image.memory(widget.imageBytes, fit: BoxFit.cover),
                                  ),
                                  for (final hs in r.hotspots)
                                    Positioned(
                                      left: hs.xPercent / 100 * w - 22,
                                      top: hs.yPercent / 100 * h - 22,
                                      child: _Pin(
                                        h: hs,
                                        active: _active == hs,
                                        onTap: () => setState(() => _active = hs),
                                      ),
                                    ),
                                  if (_active != null) _Tooltip(h: _active!, boxW: w, boxH: h),
                                ],
                              );
                            },
                          ),
                        ),
                ),
                Positioned(
                  top: 0, left: 0, right: 0,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        children: [
                          _Round(icon: Icons.arrow_back, onTap: () => Navigator.pop(context)),
                          const Spacer(),
                          _ScoreBadge(score: r.overallScore),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _BottomRail(active: _active, summary: r.overallSummary, count: r.hotspots.length),
        ],
      ),
    );
  }
}

/// Small tooltip bubble with a pointer toward its pin. Core feedback only.
class _Tooltip extends StatelessWidget {
  const _Tooltip({required this.h, required this.boxW, required this.boxH});
  final Hotspot h;
  final double boxW, boxH;

  ({String label, Color c}) get _sev => switch (h.severity) {
        'good' => (label: 'WORKS', c: AppColors.ink),
        'tip' => (label: 'TWEAK', c: AppColors.muted),
        _ => (label: 'ISSUE', c: AppColors.flag),
      };

  @override
  Widget build(BuildContext context) {
    final s = _sev;
    final pinX = h.xPercent / 100 * boxW;
    final pinY = h.yPercent / 100 * boxH;
    final below = h.yPercent < 50;
    const cardW = 200.0;
    final left = (pinX - cardW / 2).clamp(10.0, boxW - cardW - 10);

    final bubble = Container(
      width: cardW,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 6))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.label, style: TextStyle(color: s.c, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
          const SizedBox(height: 3),
          Text(h.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: -0.3)),
        ],
      ),
    );

    final pointer = CustomPaint(
      size: const Size(16, 8),
      painter: _CaretPainter(pointUp: !below),
    );

    return Positioned(
      left: left,
      top: below ? pinY + 26 : null,
      bottom: below ? null : (boxH - (pinY - 26)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (below) Padding(padding: EdgeInsets.only(left: (pinX - left - 8).clamp(8, cardW - 24)), child: pointer),
          bubble,
          if (!below) Padding(padding: EdgeInsets.only(left: (pinX - left - 8).clamp(8, cardW - 24)), child: pointer),
        ],
      ),
    );
  }
}

class _CaretPainter extends CustomPainter {
  _CaretPainter({required this.pointUp});
  final bool pointUp;
  @override
  void paint(Canvas canvas, Size s) {
    final p = Path();
    if (pointUp) {
      p..moveTo(0, s.height)..lineTo(s.width / 2, 0)..lineTo(s.width, s.height);
    } else {
      p..moveTo(0, 0)..lineTo(s.width / 2, s.height)..lineTo(s.width, 0);
    }
    canvas.drawPath(p..close, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _CaretPainter old) => old.pointUp != pointUp;
}

/// Persistent bottom rail. Shows the verdict when nothing is selected; when a
/// pin is active, shows its fix + look-suggestion cards (inspiration only —
/// NO price / cart / buy, SDD §1.3).
class _BottomRail extends StatelessWidget {
  const _BottomRail({required this.active, required this.summary, required this.count});
  final Hotspot? active;
  final String summary;
  final int count;

  @override
  Widget build(BuildContext context) {
    final a = active;
    return Container(
      width: double.infinity,
      color: AppColors.bg,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: SafeArea(
        top: false,
        child: a == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppType.body),
                  const SizedBox(height: 8),
                  Row(children: [
                    const Icon(Icons.touch_app_outlined, size: 15, color: AppColors.muted),
                    const SizedBox(width: 6),
                    Text('Tap any of the $count pins', style: AppType.label),
                  ]),
                  const SizedBox(height: 12),
                ],
              )
            : _RailContent(h: a),
      ),
    );
  }
}

class _RailContent extends StatelessWidget {
  const _RailContent({required this.h});
  final Hotspot h;
  @override
  Widget build(BuildContext context) {
    final shots = h.suggestions.where((x) => x.imageUrl != null).toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(h.title, style: AppType.h2),
        const SizedBox(height: 12),
        SizedBox(
          height: 128,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              if (h.fix != null) _FixCard(fix: h.fix!),
              for (final s in shots) ...[const SizedBox(width: 10), _LookCard(s: s)],
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _FixCard extends StatelessWidget {
  const _FixCard({required this.fix});
  final String fix;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 230,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.auto_awesome, size: 14, color: AppColors.signature),
            SizedBox(width: 6),
            Text('THE FIX', style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
          ]),
          const SizedBox(height: 8),
          Flexible(
            child: Text(fix,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, height: 1.3, fontSize: 14)),
          ),
        ],
      ),
    );
  }
}

class _LookCard extends StatelessWidget {
  const _LookCard({required this.s});
  final VisualSuggestion s;
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 92,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 92, height: 100,
              child: s.imageUrl != null ? Image.network(s.imageUrl!, fit: BoxFit.cover) : Container(color: AppColors.surface),
            ),
          ),
          const SizedBox(height: 4),
          Flexible(child: Text(s.caption, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}

class _Pin extends StatefulWidget {
  const _Pin({required this.h, required this.onTap, required this.active});
  final Hotspot h;
  final VoidCallback onTap;
  final bool active;
  @override
  State<_Pin> createState() => _PinState();
}

class _PinState extends State<_Pin> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Color get _dot => switch (widget.h.severity) {
        'good' => Colors.white,
        'tip' => const Color(0xFFBFBFBF),
        _ => AppColors.ink,
      };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 44, height: 44,
        child: Center(
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, child) {
              final t = _c.value;
              return Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 14 + t * (widget.active ? 26 : 16),
                    height: 14 + t * (widget.active ? 26 : 16),
                    decoration: BoxDecoration(shape: BoxShape.circle, color: _dot.withValues(alpha: (1 - t) * 0.3)),
                  ),
                  child!,
                ],
              );
            },
            child: Container(
              width: widget.active ? 20 : 16,
              height: widget.active ? 20 : 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _dot,
                border: Border.all(color: Colors.white, width: widget.active ? 3 : 2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScoreBadge extends StatelessWidget {
  const _ScoreBadge({required this.score});
  final int score;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(999)),
      child: RichText(
        text: TextSpan(style: const TextStyle(color: Colors.white), children: [
          TextSpan(text: '$score', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const TextSpan(text: ' / 10', style: TextStyle(fontSize: 13, color: Colors.white70)),
        ]),
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

class _Unusable extends StatelessWidget {
  const _Unusable({this.note});
  final String? note;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your review', style: AppType.h2)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.image_not_supported_outlined, size: 44, color: AppColors.muted),
              const SizedBox(height: 16),
              Text(note ?? 'That photo can\'t be analyzed. Try a clear, full-body shot in good light.',
                  textAlign: TextAlign.center, style: AppType.body),
            ],
          ),
        ),
      ),
    );
  }
}
