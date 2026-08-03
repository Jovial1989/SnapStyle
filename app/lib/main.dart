import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'providers.dart';
import 'services/analytics.dart';
import 'services/auth.dart' as auth;
import 'services/profile_store.dart';
import 'screens/auth_screen.dart';
import 'screens/demo_result_screen.dart';
import 'screens/home_shell.dart';
import 'screens/wardrobe_items_screen.dart';
import 'screens/splash_screen.dart';
import 'theme.dart';
import 'widgets/noise_overlay.dart';

// Supabase config via --dart-define (SDD §2.3 now active). Empty → skip init so
// the app still runs for the base64 critique flow during dev.
const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
// Marketing screenshot harness (not a user flow): --dart-define=DEMO=result.
const _demo = String.fromEnvironment('DEMO');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();

  if (_demo == 'result' || _demo == 'restyle') {
    if (_supabaseUrl.isNotEmpty && _supabaseAnonKey.isNotEmpty) {
      await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseAnonKey);
      try {
        await auth.ensureSession();
      } catch (_) {}
    }
    runApp(ProviderScope(child: LooktokApp(home: DemoResultScreen(restyle: _demo == 'restyle'))));
    return;
  }

  // Marketing capture harnesses — render a screen directly for a clean export.
  if (_demo == 'home' || _demo == 'wardrobe') {
    if (_supabaseUrl.isNotEmpty && _supabaseAnonKey.isNotEmpty) {
      await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseAnonKey);
      try {
        await auth.ensureSession();
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    runApp(ProviderScope(
      overrides: [profileStoreProvider.overrideWithValue(ProfileStore(prefs))],
      child: LooktokApp(home: _demo == 'wardrobe' ? const WardrobeItemsScreen() : const HomeShell()),
    ));
    return;
  }

  // Preview harness for the onboarding flow (intro slides → Vibe Check).
  if (_demo == 'onboarding') {
    if (_supabaseUrl.isNotEmpty && _supabaseAnonKey.isNotEmpty) {
      await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseAnonKey);
      try {
        await auth.ensureSession();
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    runApp(ProviderScope(
      overrides: [profileStoreProvider.overrideWithValue(ProfileStore(prefs))],
      child: const LooktokApp(home: AuthScreen()),
    ));
    return;
  }

  await Analytics.init();
  if (_supabaseUrl.isNotEmpty && _supabaseAnonKey.isNotEmpty) {
    await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseAnonKey);
    // Identify by the opaque auth uid on every auth transition (login, token
    // refresh, logout → null). Runs before ensureSession so the initial
    // session is caught too.
    Supabase.instance.client.auth.onAuthStateChange.listen((s) {
      Analytics.setUserId(s.session?.user.id);
    });
    // Dummy login: ensure an anonymous session (real JWT) so cloud calls work
    // even for returning users who skip the auth screen. Best-effort (offline ok).
    try {
      await auth.ensureSession();
    } catch (_) {/* offline / transient — cloud calls will surface 401 later */}
  }

  final prefs = await SharedPreferences.getInstance();
  final store = ProfileStore(prefs);

  runApp(
    ProviderScope(
      overrides: [profileStoreProvider.overrideWithValue(store)],
      child: const LooktokApp(),
    ),
  );
}

class LooktokApp extends StatelessWidget {
  const LooktokApp({super.key, this.home = const SplashScreen()});
  final Widget home;

  @override
  Widget build(BuildContext context) {
    // i18n root lives HERE (not per-runApp) so every harness path is covered.
    return EasyLocalization(
      supportedLocales: const [Locale('en'), Locale('es'), Locale('it'), Locale('fr'), Locale('uk')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      child: Builder(
        builder: (ctx) => MaterialApp(
          title: 'Looktok',
          debugShowCheckedModeBanner: false,
          localizationsDelegates: ctx.localizationDelegates,
          supportedLocales: ctx.supportedLocales,
          locale: ctx.locale,
          theme: buildTheme(),
          builder: (context, child) => NoiseOverlay(child: child ?? const SizedBox()),
          home: home,
        ),
      ),
    );
  }
}
