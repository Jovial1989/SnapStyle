/// Mirrors the style_profiles row returned by /api/onboarding-profile (SDD §5.5).
/// Measurements are RANGES, never exact — the UI must present them as such.
class MeasureRange {
  final num? min;
  final num? max;
  const MeasureRange(this.min, this.max);

  factory MeasureRange.fromJson(Map<String, dynamic>? j) =>
      MeasureRange((j?['min'] as num?), (j?['max'] as num?));

  String? get label => (min == null || max == null)
      ? null
      : '${min!.round()}–${max!.round()} cm';
}

class BodyProfile {
  final double heightCm;
  final String? bodyType;
  final String? proportionDescription;
  final MeasureRange chest, waist, hip, inseam;
  final double? confidence;
  final List<String> stylingNotes;

  const BodyProfile({
    required this.heightCm,
    this.bodyType,
    this.proportionDescription,
    required this.chest,
    required this.waist,
    required this.hip,
    required this.inseam,
    this.confidence,
    this.stylingNotes = const [],
  });

  factory BodyProfile.fromResponse(Map<String, dynamic> res) {
    final p = (res['profile'] as Map).cast<String, dynamic>();
    final prop = (p['proportions'] as Map?)?.cast<String, dynamic>() ?? const {};
    final m = (p['estimated_measurements'] as Map?)?.cast<String, dynamic>() ?? const {};
    Map<String, dynamic>? sub(String k) => (m[k] as Map?)?.cast<String, dynamic>();
    return BodyProfile(
      heightCm: (p['height_cm'] as num).toDouble(),
      bodyType: p['body_type'] as String?,
      proportionDescription: prop['description'] as String?,
      chest: MeasureRange.fromJson(sub('chest_cm')),
      waist: MeasureRange.fromJson(sub('waist_cm')),
      hip: MeasureRange.fromJson(sub('hip_cm')),
      inseam: MeasureRange.fromJson(sub('inseam_cm')),
      confidence: (p['confidence'] as num?)?.toDouble(),
      stylingNotes:
          ((res['stylingNotes'] as List?) ?? const []).map((e) => e.toString()).toList(),
    );
  }
}
