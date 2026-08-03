import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../services/auth.dart' as auth;
import '../theme.dart';
import '../widgets/wordmark.dart';
import 'home_shell.dart';
import 'onboarding_screen.dart';
import 'vibe_check_screen.dart';
import 'select_looks_screen.dart';

/// First-run: "show, don't tell" onboarding (SDD §14.2 / §9.7).
/// Each slide = top 60% rich media mockup + bottom 40% copy/CTA.
/// Auth is a LOCAL STUB — real Supabase Auth lands when Supabase is on.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});
  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  // 0..3 = story beats, 4 = the account form. One static scaffold, the
  // content cross-fades inside it; swipe OR tap advances.
  int _step = 0;

  Future<void> _finish() async {
    // Dummy login → real anonymous Supabase session (idempotent, no-op if cloud off).
    try {
      await auth.ensureSession();
    } catch (_) {/* offline / transient — proceed; cloud calls will retry */}
    await ref.read(profileStoreProvider).setSignedIn(true);

    // Offer the body profile right after sign-up (skippable here; enforced later
    // as a hard gate before any review/look flow — SDD §14).
    var needsProfile = false;
    if (ref.read(cloudEnabledProvider)) {
      try {
        needsProfile = !await ref.read(looktokApiProvider).hasBodyProfile();
      } catch (_) {/* offline — offer anyway */ needsProfile = true;}
    }
    if (!mounted) return;
    if (needsProfile) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const OnboardingScreen(skippable: true)));
      if (!mounted) return;
      // Visual "Style DNA" (SDD §14.12) — skippable; falls back to a smart anchor.
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VibeCheckScreen()));
      if (!mounted) return;
      // "Your looks" — optional 2–10 photos → silent personal lookbook (skippable).
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SelectLooksScreen()));
      if (!mounted) return;
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const HomeShell()));
  }

  void _next() {
    if (_step < 4) {
      HapticFeedback.selectionClick();
      setState(() => _step++);
    }
  }

  void _prev() {
    if (_step > 0 && _step < 4) {
      HapticFeedback.selectionClick();
      setState(() => _step--);
    }
  }

  static const _story = [
    (heading: 'Honest,\nnot flattering.', body: 'One mirror photo. A real read on how your fit actually lands — fit, proportion, colour, footwear.', cta: 'Next'),
    (heading: 'Deep AI Analysis.', body: 'It maps your proportions, fit and style geometry — the same things a good stylist reads.', cta: 'Next'),
    (heading: 'Your ultimate fit.', body: 'Every idea is rendered on YOUR photo — not a model. Swap any piece and see it instantly.', cta: 'Next'),
    (heading: 'It learns\nyour taste.', body: 'Add your height and a few looks you love — yours or anyone\'s. The AI dresses you from them.', cta: 'Get Started'),
  ];

  Widget _stageFor(int step) => switch (step) {
        0 => const _RawStage(),
        1 => const _ScanStage(),
        2 => const _RevealStage(),
        _ => const _TasteStage(),
      };

  @override
  Widget build(BuildContext context) {
    final onStory = _step < 4;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          // ── The living content: story beat or the account form, swapped by
          // one 500ms fade + whisper of scale. The scaffold never moves. ──
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragEnd: onStory
                  ? (d) {
                      final v = d.primaryVelocity ?? 0;
                      if (v < -200) _next();
                      if (v > 200) _prev();
                    }
                  : null,
              child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 500),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: ScaleTransition(
                  scale: Tween(begin: 0.985, end: 1.0).animate(anim),
                  child: child,
                ),
              ),
              child: KeyedSubtree(
                key: ValueKey(_step),
                child: onStory
                    ? _StoryContent(
                        media: _stageFor(_step),
                        heading: _story[_step].heading,
                        body: _story[_step].body,
                      )
                    : _AuthPage(onDone: _finish),
              ),
              ),
            ),
          ),
          // ── Fixed footer: plain conditional (a transition wrapper once ate
          // the button on-device — never again). ──
          if (onStory)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 14),
                child: Row(children: [
                  _Dots(index: _step),
                  const Spacer(),
                  SizedBox(
                    height: 50,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.ink,
                        foregroundColor: Colors.white,
                        // The app theme sets minimumSize.fromHeight(58) =
                        // INFINITE width — inside this Row (unbounded after
                        // Spacer) the button collapsed to nothing. Twice.
                        minimumSize: const Size(0, 50),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999)),
                      ),
                      onPressed: _next,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(_story[_step].cta,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 15)),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_forward, size: 17),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

/// One story beat: stage + copy. The footer lives OUTSIDE (fixed) — this
/// widget is what the AnimatedSwitcher cross-fades.
class _StoryContent extends StatelessWidget {
  const _StoryContent({required this.media, required this.heading, required this.body});
  final Widget media;
  final String heading, body;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        flex: 11,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(24)),
            child: media,
          ),
        ),
      ),
      Expanded(
        flex: 6,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(heading, style: AppType.display),
              const SizedBox(height: 10),
              Text(body, style: AppType.body),
            ],
          ),
        ),
      ),
    ]);
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.index});
  final int index;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(4, (i) {
        final on = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.only(right: 7),
          width: on ? 26 : 7,
          height: 7,
          decoration: BoxDecoration(
            color: on ? AppColors.ink : const Color(0xFFE2E2DE),
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}

/// First-existing-asset image: lets wife/founder shots slot in by filename
/// with zero code changes (drop wife_1.jpg / wife_2.jpg into
/// assets/onboarding/ and rebuild).
class _SmartAsset extends StatelessWidget {
  const _SmartAsset({required this.candidates});
  final List<String> candidates;

  Future<String> _resolve(BuildContext context) async {
    for (final c in candidates) {
      try {
        await DefaultAssetBundle.of(context).load(c);
        return c;
      } catch (_) {/* next candidate */}
    }
    return candidates.last;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _resolve(context),
      builder: (_, s) => s.hasData
          ? Image(image: AssetImage(s.data!), fit: BoxFit.cover)
          : const ColoredBox(color: Color(0xFFF0F0F3)),
    );
  }
}

// ── Stage 1: honest reality — the founder's real mirror photo ─────────────
class _RawStage extends StatelessWidget {
  const _RawStage();
  @override
  Widget build(BuildContext context) => const _SmartAsset(
      candidates: ['assets/onboarding/story_real.jpg']);
}

// ── Stage 4: taste — looks you love teach the model (wife's shots when
// present; the founder's restyle otherwise) ────────────────────────────────
class _TasteStage extends StatelessWidget {
  const _TasteStage();
  @override
  Widget build(BuildContext context) => const _SmartAsset(candidates: [
        'assets/onboarding/wife_1.jpg',
        'assets/onboarding/story_taste.jpg',
      ]);
}

// ── Stage 2: the magic — a volumetric scanner breathes over the SAME photo,
// with a glassmorphic AI SCAN badge. No hard scan lines, no frames. ─────────
class _ScanStage extends StatefulWidget {
  const _ScanStage();
  @override
  State<_ScanStage> createState() => _ScanStageState();
}

class _ScanStageState extends State<_ScanStage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2600))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      const _SmartAsset(candidates: [
        'assets/onboarding/wife_2.jpg',
        'assets/onboarding/story_real.jpg',
      ]),
      // Soft volumetric band gliding up and down — pure gradient, no edges.
      AnimatedBuilder(
        animation: _c,
        builder: (_, _) {
          final y = -1.25 + 2.5 * Curves.easeInOut.transform(_c.value);
          return Align(
            alignment: Alignment(0, y),
            child: FractionallySizedBox(
              widthFactor: 1,
              heightFactor: 0.42,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.signature.withValues(alpha: 0),
                      AppColors.signature.withValues(alpha: 0.16),
                      Colors.white.withValues(alpha: 0.22),
                      AppColors.signature.withValues(alpha: 0.16),
                      AppColors.signature.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
      // Glassmorphic badge — frosted, hairline white border.
      Positioned(
        top: 14, left: 14,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white.withValues(alpha: 0.45)),
              ),
              child: const Text('AI SCAN',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.6)),
            ),
          ),
        ),
      ),
    ]);
  }
}

// ── Stage 3: the transformation — the fixed fit, revealed with a soft
// scale-in. Scanner gone; the result speaks alone. ──────────────────────────
class _RevealStage extends StatelessWidget {
  const _RevealStage();
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.94, end: 1),
      duration: const Duration(milliseconds: 640),
      curve: Curves.easeOutCubic,
      builder: (_, sc, child) => Transform.scale(scale: sc, child: child),
      child: const _SmartAsset(
          candidates: ['assets/onboarding/story_fix.jpg']),
    );
  }
}

class _AuthPage extends StatefulWidget {
  const _AuthPage({required this.onDone});
  final VoidCallback onDone;
  @override
  State<_AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<_AuthPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _signIn = false; // false = create account, true = welcome back
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final pass = _password.text;
    if (email.isEmpty || pass.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter your email and password.')));
      return;
    }
    setState(() => _busy = true);
    try {
      if (_signIn) {
        await auth.signIn(email, pass);
      } else {
        await auth.signUp(email, pass);
      }
      if (!mounted) return;
      widget.onDone();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final msg = e.toString().contains('Invalid login')
          ? 'Wrong email or password.'
          : e.toString().contains('already registered')
              ? 'This email already has an account — sign in instead.'
              : 'Couldn\'t ${_signIn ? 'sign you in' : 'create the account'} — try again.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// Tactile input: soft fill, 16px radius, whisper of shadow — no hard
  /// borders anywhere (the quiet-luxury register of the story steps).
  Widget _field({required String hint, bool obscure = false, TextEditingController? controller}) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Color(0x0A000000), blurRadius: 14, offset: Offset(0, 5)),
        ],
      ),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        keyboardType: obscure ? TextInputType.text : TextInputType.emailAddress,
        autocorrect: false,
        style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(
              color: AppColors.muted, fontWeight: FontWeight.w500),
          filled: true,
          fillColor: const Color(0xFFF4F4F2),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: AppColors.signature, width: 1.4),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Scroll-safe: when the keyboard opens the Spacers used to squeeze the
    // bottom CTA off-screen. LayoutBuilder + scroll + IntrinsicHeight keeps the
    // spaced layout when there's room and scrolls (nothing clipped) when tight.
    return LayoutBuilder(builder: (context, c) {
      return SingleChildScrollView(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: IntrinsicHeight(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Logo(size: 20),
                  const Spacer(),
                  Text(_signIn ? 'Welcome\nback.' : 'Create your\naccount',
                      style: AppType.display),
          const SizedBox(height: 24),
          _field(hint: 'Email', controller: _email),
          const SizedBox(height: 12),
          _field(hint: 'Password', obscure: true, controller: _password),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.ink,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999)),
              ),
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(_signIn ? 'Sign in' : 'Continue',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15.5)),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                backgroundColor: const Color(0xFFF4F4F2),
                foregroundColor: AppColors.ink,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999)),
              ),
              onPressed: widget.onDone, // Google OAuth stub (SDD §14.2)
              icon: const Icon(Icons.g_mobiledata, size: 26),
              label: const Text('Continue with Google',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
          ),
          const SizedBox(height: 14),
          Center(
            child: TextButton(
              onPressed: () => setState(() => _signIn = !_signIn),
              child: Text(
                _signIn
                    ? 'New here? Create an account'
                    : 'Already have an account? Sign in',
                style: const TextStyle(
                    color: AppColors.inkSoft,
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5),
              ),
            ),
          ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}
