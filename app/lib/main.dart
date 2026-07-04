import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'providers.dart';
import 'services/profile_store.dart';
import 'screens/splash_screen.dart';
import 'theme.dart';
import 'widgets/noise_overlay.dart';

// Supabase config via --dart-define (SDD §2.3 now active). Empty → skip init so
// the app still runs for the base64 critique flow during dev.
const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_supabaseUrl.isNotEmpty && _supabaseAnonKey.isNotEmpty) {
    await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseAnonKey);
  }

  final prefs = await SharedPreferences.getInstance();
  final store = ProfileStore(prefs);

  runApp(
    ProviderScope(
      overrides: [profileStoreProvider.overrideWithValue(store)],
      child: const SnapstyleApp(),
    ),
  );
}

class SnapstyleApp extends StatelessWidget {
  const SnapstyleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Snapstyle',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      builder: (context, child) => NoiseOverlay(child: child ?? const SizedBox()),
      home: const SplashScreen(),
    );
  }
}
