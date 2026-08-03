import 'package:flutter/material.dart';

/// Looktok design tokens — black & white editorial (2026 redesign).
/// Palette is monochrome: ink on near-white, thin hairlines, generous space.
/// Primary action = solid black (SHEIN/aesthetic register). No color accent.
class AppColors {
  static const bg = Color(0xFFF8F8F8); // subtle off-white base (not pure #fff)
  static const surface = Color(0xFFEFEFEE); // cards / inputs (light grey)
  static const surfaceHi = Color(0xFFFFFFFF); // top highlight for inset cards
  static const ink = Color(0xFF0A0A0A); // text + primary buttons
  static const inkSoft = Color(0xFF3A3A3A);
  static const muted = Color(0xFF8C8C88); // secondary text
  static const line = Color(0xFFE4E4E1); // hairlines
  static const onInk = Color(0xFFF8F8F8); // text on black

  /// Single signature accent — used SPARINGLY (logo period, AI/sparkle icons).
  /// Flip to Acid Lime (0xFFC7F026) here to change the whole brand accent.
  static const signature = Color(0xFF2E5BFF); // electric blue

  // Kept for API compatibility; resolve to ink (no color accent on surfaces).
  static const accent = ink;
  static const accentPressed = Color(0xFF000000);

  // Functional only (severity flags) — used on result zones, not brand color.
  static const flag = Color(0xFF9B2C2C); // issue
  static const good = Color(0xFF1E9E6A); // works / keep
}

/// Geometry system — ONE radius scale app-wide (SDD D-3). Circles are reserved
/// for pins and icon dots.
class AppRadius {
  static const double hero = 28; // sheets + hero action cards
  static const double card = 20; // default cards
  static const double control = 12; // inputs, thumbnails, small chips
  // Primary ACTION buttons are full pills — the app-wide standard set by the
  // try-on screen's "Style my whole look" / "Wear this" CTAs. Every primary
  // button matches this so buttons don't read differently screen-to-screen.
  static const double pill = 999;
}

/// Exactly two surface treatments (SDD D-2): pure white + one soft diffused
/// shadow (default), or stark black (high-emphasis). No gray blocks, no blur
/// on regular cards — glass only over photos.
class AppShadows {
  static const soft = [
    BoxShadow(color: Color(0x0D000000), blurRadius: 30, offset: Offset(0, 10)),
  ];
}

class AppSurfaces {
  static BoxDecoration card = BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(AppRadius.card),
    boxShadow: AppShadows.soft,
  );
  static BoxDecoration ink = BoxDecoration(
    color: AppColors.ink,
    borderRadius: BorderRadius.circular(AppRadius.card),
    boxShadow: const [
      BoxShadow(color: Color(0x33000000), blurRadius: 30, offset: Offset(0, 12)),
    ],
  );
}

/// Reusable surface decorations.
class AppDecorations {
  /// Micro-neumorphic inset card: light-grey fill, 1px top white highlight,
  /// soft outer lift + a faint inner-top gradient to read as recessed hardware.
  /// (Flutter has no true inset shadow; this is a refined approximation.)
  // Note: Flutter forbids a multi-color Border with borderRadius, so the top
  // white highlight is done via the gradient + a white inner-top shadow, and the
  // border is a single uniform hairline.
  static BoxDecoration neuCard = BoxDecoration(
    borderRadius: BorderRadius.circular(16),
    gradient: const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFFAFAF9), Color(0xFFE9E9E7)], // light top → recessed bottom
    ),
    border: Border.all(color: const Color(0xFFDCDCD9)),
    boxShadow: const [
      BoxShadow(color: Color(0x0F000000), blurRadius: 10, offset: Offset(0, 4)),
      BoxShadow(color: Color(0xCCFFFFFF), blurRadius: 0, offset: Offset(0, 1), spreadRadius: -1),
    ],
  );
}

ThemeData buildTheme() {
  final base = ThemeData.light(useMaterial3: true);
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.ink,
    brightness: Brightness.light,
  ).copyWith(
    surface: AppColors.bg,
    onSurface: AppColors.ink,
    primary: AppColors.ink,
    onPrimary: AppColors.onInk,
  );

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: scheme,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      foregroundColor: AppColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      // One consistent title style across every screen (matches AppType.h2 used
      // on My Looks). No colour → each screen's foregroundColor applies.
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.4),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.ink,
        foregroundColor: AppColors.onInk,
        minimumSize: const Size.fromHeight(58),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
        textStyle: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.ink,
        minimumSize: const Size.fromHeight(58),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        side: const BorderSide(color: AppColors.ink, width: 1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 0.3),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: Colors.white,
      side: const BorderSide(color: AppColors.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
      labelStyle: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: const BorderSide(color: AppColors.ink, width: 1.5),
      ),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.ink,
      displayColor: AppColors.ink,
    ),
  );
}

/// Editorial type helpers (tight tracking, heavy display).
class AppType {
  static const display = TextStyle(
    fontSize: 40,
    height: 1.0,
    fontWeight: FontWeight.w800,
    letterSpacing: -1.5,
    color: AppColors.ink,
  );
  static const h2 = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    color: AppColors.ink,
  );
  static const body = TextStyle(fontSize: 15, height: 1.45, color: AppColors.inkSoft);
  static const label = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
    color: AppColors.muted,
  );
}
