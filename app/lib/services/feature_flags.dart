import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Remote feature flags (Supabase `feature_flags` table: key → enabled) with
/// a two-tier cache and a local dev override.
///
/// Read path for [useSam2Engine], in priority order:
///   1. DEV OVERRIDE (SharedPreferences, set from the hidden Dev Settings
///      screen) — bypasses remote entirely when ON;
///   2. in-memory cache (15-min TTL) — screens/pipelines never hit the DB
///      per call;
///   3. Supabase `feature_flags` row;
///   4. last-known value persisted in prefs (offline / table missing / any
///      error) — and finally `false`, the safe default.
class FeatureFlagService {
  static const _flagKey = 'use_sam2_engine';
  static const _overridePref = 'dev.force_sam2_engine';
  static const _lastKnownPref = 'flags.use_sam2_engine';
  static const _ttl = Duration(minutes: 15);

  bool? _memory;
  DateTime? _fetchedAt;

  // ── Dev override (hidden menu) ────────────────────────────────────────────
  Future<bool> forceSam2() async =>
      (await SharedPreferences.getInstance()).getBool(_overridePref) ?? false;

  Future<void> setForceSam2(bool value) async =>
      (await SharedPreferences.getInstance()).setBool(_overridePref, value);

  // ── Remote flag ───────────────────────────────────────────────────────────
  /// The raw remote value (cached). Never throws.
  Future<bool> remoteUseSam2({bool refresh = false}) async {
    final at = _fetchedAt;
    if (!refresh && _memory != null && at != null && DateTime.now().difference(at) < _ttl) {
      return _memory!;
    }
    try {
      final row = await Supabase.instance.client
          .from('feature_flags')
          .select('enabled')
          .eq('key', _flagKey)
          .maybeSingle();
      final v = (row?['enabled'] as bool?) ?? false;
      _memory = v;
      _fetchedAt = DateTime.now();
      (await SharedPreferences.getInstance()).setBool(_lastKnownPref, v);
      return v;
    } catch (_) {
      // Offline, signed out, or the table isn't there yet — degrade to the
      // last value this device saw, then to the safe default.
      return _memory ??
          (await SharedPreferences.getInstance()).getBool(_lastKnownPref) ??
          false;
    }
  }

  /// The single question the pipeline asks: run the experimental engine?
  Future<bool> useSam2Engine() async => await forceSam2() || await remoteUseSam2();
}
