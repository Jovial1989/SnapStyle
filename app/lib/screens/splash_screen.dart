import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theme.dart';
import '../widgets/wordmark.dart';
import 'auth_screen.dart';
import 'home_shell.dart';

/// Branded splash — full logo lockup (mark + wordmark + name) with a calm
/// fade/rise, then routes to auth or home. The native Android-12 splash can
/// only show the icon; this adds the name (SDD §9.1).
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});
  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..forward();
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      final signedIn = ref.read(profileStoreProvider).signedIn();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => signedIn ? const HomeShell() : const AuthScreen()),
      );
    });
  }

  @override
  void dispose() {
    _c.dispose();
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = CurvedAnimation(parent: _c, curve: Curves.easeOut);
    return Scaffold(
      body: Center(
        child: FadeTransition(
          opacity: fade,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.06), end: Offset.zero).animate(fade),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LensMark(size: 56),
                const SizedBox(height: 18),
                const Wordmark(size: 30),
                const SizedBox(height: 10),
                Text(
                  'YOUR AI STYLIST',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 3,
                    color: AppColors.muted,
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
