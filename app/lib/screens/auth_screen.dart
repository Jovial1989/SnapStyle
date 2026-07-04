import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theme.dart';
import '../widgets/wordmark.dart';
import 'home_shell.dart';

/// First-run: "show, don't tell" onboarding (SDD §14.2 / §9.7).
/// Each slide = top 60% rich media mockup + bottom 40% copy/CTA.
/// Auth is a LOCAL STUB — real Supabase Auth lands when Supabase is on.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});
  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _pager = PageController();

  Future<void> _finish() async {
    await ref.read(profileStoreProvider).setSignedIn(true);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const HomeShell()));
  }

  void _next() =>
      _pager.nextPage(duration: const Duration(milliseconds: 320), curve: Curves.easeOut);

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: PageView(
          controller: _pager,
          children: [
            _Slide(
              media: const _ScanMock(),
              dotIndex: 0,
              heading: 'Honest,\nnot flattering.',
              body: 'One photo. A real read on how your fit actually lands.',
              cta: 'Next',
              onCta: _next,
            ),
            _Slide(
              media: const _PinsMock(),
              dotIndex: 1,
              heading: 'See the fix.',
              body: 'Tap the pins to get actionable, brand-agnostic style upgrades.',
              cta: 'Next',
              onCta: _next,
            ),
            _AuthPage(onDone: _finish),
          ],
        ),
      ),
    );
  }
}

/// 60/40 layout: media on top, copy + CTA + page dots on the bottom.
class _Slide extends StatelessWidget {
  const _Slide({
    required this.media,
    required this.heading,
    required this.body,
    required this.cta,
    required this.onCta,
    required this.dotIndex,
  });
  final Widget media;
  final String heading, body, cta;
  final VoidCallback onCta;
  final int dotIndex;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          flex: 6,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: ClipRRect(borderRadius: BorderRadius.circular(24), child: media),
          ),
        ),
        Expanded(
          flex: 4,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(heading, style: AppType.display),
                const SizedBox(height: 12),
                Text(body, style: AppType.body),
                const Spacer(),
                _Dots(index: dotIndex),
                const SizedBox(height: 14),
                FilledButton(onPressed: onCta, child: Text(cta)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.index});
  final int index;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(3, (i) {
        final on = i == index;
        return Container(
          margin: const EdgeInsets.only(right: 6),
          width: on ? 20 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: on ? AppColors.ink : AppColors.line,
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }
}

// ── Media mock 1: AI scanning ──────────────────────────────────────────────
class _ScanMock extends StatefulWidget {
  const _ScanMock();
  @override
  State<_ScanMock> createState() => _ScanMockState();
}

class _ScanMockState extends State<_ScanMock> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => CustomPaint(painter: _ScanMockPainter(_c.value), size: Size.infinite),
    );
  }
}

class _ScanMockPainter extends CustomPainter {
  _ScanMockPainter(this.t);
  final double t;
  @override
  void paint(Canvas canvas, Size s) {
    canvas.drawRect(Offset.zero & s, Paint()..color = AppColors.surface);
    _paintFigure(canvas, s);

    // One calm detection frame around the subject.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(s.width * 0.24, s.height * 0.06, s.width * 0.52, s.height * 0.86),
        const Radius.circular(18),
      ),
      Paint()
        ..color = AppColors.signature.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Slow scan line + soft glow band.
    final y = t * s.height;
    final band = Rect.fromLTWH(0, y - 26, s.width, 52);
    canvas.drawRect(
      band,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.signature.withValues(alpha: 0),
            AppColors.signature.withValues(alpha: 0.18),
            AppColors.signature.withValues(alpha: 0),
          ],
        ).createShader(band),
    );
    canvas.drawLine(Offset(0, y), Offset(s.width, y),
        Paint()..color = AppColors.signature..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _ScanMockPainter old) => old.t != t;
}

// ── Media mock 2: interactive pins + peeking sheet ─────────────────────────
class _PinsMock extends StatefulWidget {
  const _PinsMock();
  @override
  State<_PinsMock> createState() => _PinsMockState();
}

class _PinsMockState extends State<_PinsMock> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedBuilder(
          animation: _c,
          builder: (_, _) => CustomPaint(painter: _PinsMockPainter(_c.value), size: Size.infinite),
        ),
        // Peeking bottom sheet with a suggestion row.
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
            decoration: const BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                        color: AppColors.flag.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(5)),
                    child: const Text('ISSUE',
                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.flag))),
                const SizedBox(height: 6),
                const Text('Pants too long',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 10),
                Row(
                  children: List.generate(
                    3,
                    (_) => Container(
                      width: 46,
                      height: 56,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                          color: AppColors.surface, borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.auto_awesome_outlined, size: 16, color: AppColors.muted),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PinsMockPainter extends CustomPainter {
  _PinsMockPainter(this.t);
  final double t;
  @override
  void paint(Canvas canvas, Size s) {
    canvas.drawRect(Offset.zero & s, Paint()..color = AppColors.surface);
    _paintFigure(canvas, s);

    // Calm pins at shoulder / waist / ankle (subtle breathing halo).
    const spots = [Offset(0.62, 0.30), Offset(0.44, 0.52), Offset(0.52, 0.80)];
    for (final sp in spots) {
      final c = Offset(sp.dx * s.width, sp.dy * s.height);
      canvas.drawCircle(c, 6 + t * 9,
          Paint()..color = AppColors.ink.withValues(alpha: (1 - t) * 0.18));
      canvas.drawCircle(c, 6, Paint()..color = AppColors.ink);
      canvas.drawCircle(c, 6,
          Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(covariant _PinsMockPainter old) => old.t != t;
}

/// Shared minimal grey figure (stylized "photo" placeholder).
void _paintFigure(Canvas canvas, Size s) {
  final c = Offset(s.width / 2, s.height * 0.14);
  final grey = Paint()..color = const Color(0xFFDBDBD8);
  final headR = s.width * 0.09;
  canvas.drawCircle(c, headR, grey);
  final bodyTop = c.dy + headR * 1.5;
  canvas.drawRRect(
    RRect.fromRectAndCorners(
      Rect.fromLTRB(s.width * 0.30, bodyTop, s.width * 0.70, s.height * 0.92),
      topLeft: Radius.circular(s.width * 0.20),
      topRight: Radius.circular(s.width * 0.20),
      bottomLeft: const Radius.circular(24),
      bottomRight: const Radius.circular(24),
    ),
    grey,
  );
}

class _AuthPage extends StatelessWidget {
  const _AuthPage({required this.onDone});
  final VoidCallback onDone;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Logo(size: 20),
          const Spacer(),
          const Text('Create your\naccount', style: AppType.display),
          const SizedBox(height: 20),
          const TextField(decoration: InputDecoration(labelText: 'Email')),
          const SizedBox(height: 12),
          const TextField(obscureText: true, decoration: InputDecoration(labelText: 'Password')),
          const SizedBox(height: 20),
          FilledButton(onPressed: onDone, child: const Text('Continue')),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onDone, // Google OAuth stub (SDD §14.2)
            icon: const Icon(Icons.g_mobiledata, size: 26),
            label: const Text('Continue with Google'),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}
