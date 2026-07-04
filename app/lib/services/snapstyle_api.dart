import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/body_profile.dart';

/// Backend + Supabase-storage integration for the onboarding/try-on flows.
/// Auth is real now: every backend call carries the Supabase access token, and
/// storage uploads land in the user's own folder (RLS-enforced).
class SnapstyleApi {
  SnapstyleApi({String? baseUrl})
      : baseUrl = baseUrl ??
            const String.fromEnvironment('API_BASE',
                defaultValue: 'http://10.0.2.2:4242');

  final String baseUrl;
  SupabaseClient get _sb => Supabase.instance.client;

  String get _uid => _sb.auth.currentUser!.id;

  Map<String, String> get _authHeaders {
    final token = _sb.auth.currentSession?.accessToken;
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  /// Upload image bytes to a private bucket under the user's folder.
  /// Returns the storage path to hand to the backend.
  Future<String> uploadPhoto(Uint8List bytes, {String bucket = 'body-photos'}) async {
    final path = '$_uid/${DateTime.now().millisecondsSinceEpoch}.jpg';
    await _sb.storage.from(bucket).uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
        );
    return path;
  }

  /// Onboarding body profiling (synchronous — single Gemini call).
  Future<BodyProfile> onboardingProfile({
    required String photoPath,
    required int heightCm,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/onboarding-profile'),
      headers: _authHeaders,
      body: jsonEncode({'photoPath': photoPath, 'heightCm': heightCm}),
    );
    if (res.statusCode == 422) {
      throw ApiError((jsonDecode(res.body)['note'] ?? 'Photo unusable').toString());
    }
    if (res.statusCode != 200) {
      throw ApiError('Profiling failed (${res.statusCode})');
    }
    return BodyProfile.fromResponse(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Kick off an async Virtual Try-On. Returns the generationId to watch.
  Future<String> generateLook({required String photoPath, required String event}) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/generate-look'),
      headers: _authHeaders,
      body: jsonEncode({'photoPath': photoPath, 'event': event}),
    );
    if (res.statusCode == 402) throw ApiError('You\'ve used your free looks.');
    if (res.statusCode != 202) throw ApiError('Could not start generation (${res.statusCode})');
    return (jsonDecode(res.body)['generationId']).toString();
  }

  /// Realtime stream of a single generation row (Flow 2 completion).
  Stream<Map<String, dynamic>> watchGeneration(String generationId) {
    return _sb
        .from('generations')
        .stream(primaryKey: ['id'])
        .eq('id', generationId)
        .map((rows) => rows.isEmpty ? <String, dynamic>{} : rows.first);
  }
}

class ApiError implements Exception {
  final String message;
  ApiError(this.message);
  @override
  String toString() => message;
}
