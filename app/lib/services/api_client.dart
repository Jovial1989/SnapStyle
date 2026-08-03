import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/analysis.dart';
import '../models/body_profile.dart';
import '../models/profile.dart';

/// Thrown when the free quota is exhausted and the user isn't `pro` (HTTP 402).
class PaywallRequired implements Exception {
  final Map<String, dynamic>? entitlement;
  PaywallRequired(this.entitlement);
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

/// Compare identity guard tripped: some uploaded selfies show a DIFFERENT
/// person than the account's reference photo. No credit was burned.
class IdentityMismatchException extends ApiException {
  IdentityMismatchException(this.mismatchedIndexes)
      : super('These photos don’t look like you.');
  final List<int> mismatchedIndexes;
}

/// Talks to the Node orchestration layer (SDD §4.2).
/// Base URL overridable at build time: --dart-define=API_BASE=...
/// Default targets the Android emulator host (10.0.2.2); iOS sim uses localhost.
class ApiClient {
  ApiClient({String? baseUrl})
      : baseUrl = baseUrl ??
            const String.fromEnvironment(
              'API_BASE',
              defaultValue: 'http://10.0.2.2:4242',
            );

  final String baseUrl;

  Future<Map<String, dynamic>> entitlement(String appUserId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/entitlement?appUserId=$appUserId'),
    );
    if (res.statusCode != 200) {
      throw ApiException('entitlement failed (${res.statusCode})');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// POST /analyze with a base64 image + optional profile context.
  Future<AnalysisResult> analyze({
    required String appUserId,
    required String base64Image,
    required String mimeType,
    StyleProfile? profile,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/analyze'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'appUserId': appUserId,
        'image': {'data': base64Image, 'mimeType': mimeType},
        if (profile?.toApiJson() != null) 'profile': profile!.toApiJson(),
      }),
    );

    if (res.statusCode == 402) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      throw PaywallRequired(body['entitlement'] as Map<String, dynamic>?);
    }
    if (res.statusCode != 200) {
      throw ApiException('analysis failed (${res.statusCode})');
    }
    return AnalysisResult.fromResponse(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Local onboarding body profiling (base64, no auth/Supabase). Mirrors the
  /// critique transport; production uses the Supabase path in LooktokApi.
  Future<BodyProfile> onboardingProfileLocal({
    required String base64Image,
    required String mimeType,
    required int heightCm,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/onboarding-profile-local'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'heightCm': heightCm,
        'image': {'data': base64Image, 'mimeType': mimeType},
      }),
    );
    if (res.statusCode == 422) {
      throw ApiException((jsonDecode(res.body)['note'] ?? 'Photo unusable').toString());
    }
    if (res.statusCode != 200) {
      throw ApiException('Profiling failed (${res.statusCode})');
    }
    return BodyProfile.fromResponse(jsonDecode(res.body) as Map<String, dynamic>);
  }
}
