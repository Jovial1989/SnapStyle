import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/profile.dart';

/// On-device persistence for the profile + a stable local user id (SDD §7, §2.3).
/// The id doubles as the RevenueCat app_user_id / analyze appUserId until Supabase
/// Auth replaces it with a real authenticated id.
class ProfileStore {
  ProfileStore(this._prefs);
  final SharedPreferences _prefs;

  static const _kProfile = 'style_profile';
  static const _kUserId = 'app_user_id';
  static const _kSignedIn = 'signed_in';

  /// Interim local auth flag. Real auth = Supabase (email/pass + Google OAuth), SDD §14.
  bool signedIn() => _prefs.getBool(_kSignedIn) ?? false;
  Future<void> setSignedIn(bool v) => _prefs.setBool(_kSignedIn, v);

  String appUserId() {
    var id = _prefs.getString(_kUserId);
    if (id == null || id.isEmpty) {
      id = _generateId();
      _prefs.setString(_kUserId, id);
    }
    return id;
  }

  StyleProfile load() {
    final raw = _prefs.getString(_kProfile);
    if (raw == null) return StyleProfile.empty;
    try {
      return StyleProfile.fromStorageJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return StyleProfile.empty;
    }
  }

  Future<void> save(StyleProfile p) async {
    await _prefs.setString(_kProfile, jsonEncode(p.toStorageJson()));
  }

  static String _generateId() {
    final r = Random();
    final n = List.generate(16, (_) => r.nextInt(256));
    return 'u_${n.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }
}
