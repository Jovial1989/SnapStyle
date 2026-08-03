import 'dart:async';
import 'package:flutter/material.dart';

/// Single-line typographic loader: cycles phrases with a fade-THROUGH (the
/// outgoing line is fully gone before the incoming appears — never two strings
/// on top of each other). Honors reduced motion with a hard swap. (SDD D-4)
class StatusCycler extends StatefulWidget {
  const StatusCycler({
    super.key,
    required this.phrases,
    this.style,
    this.interval = const Duration(milliseconds: 1900),
    this.textAlign = TextAlign.center,
  });
  final List<String> phrases;
  final TextStyle? style;
  final Duration interval;
  final TextAlign textAlign;

  @override
  State<StatusCycler> createState() => _StatusCyclerState();
}

class _StatusCyclerState extends State<StatusCycler> {
  Timer? _timer;
  int _i = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.interval, (_) {
      if (mounted) setState(() => _i = (_i + 1) % widget.phrases.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.of(context).disableAnimations;
    final text = Text(
      widget.phrases[_i],
      key: ValueKey(_i),
      style: widget.style,
      textAlign: widget.textAlign,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (reduced) return text; // hard swap, no fade
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 480),
      // Fade-through: outgoing is invisible during the first half, incoming
      // only appears in the second half — the two never overlap.
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: CurveTween(curve: const Interval(0.55, 1, curve: Curves.easeOut)).animate(anim),
        child: child,
      ),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.center,
        children: [...previous, ?current],
      ),
      child: text,
    );
  }
}
