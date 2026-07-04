/// User style profile (SDD §7). All fields optional — analysis works with none.
/// Interim: stored on-device, sent to /analyze as the `profile` context object.
class StyleProfile {
  final int? heightCm;
  final String? build; // slim | average | athletic | curvy | plus
  final String? shoeSize;
  final int? shoulderCm, waistCm, hipCm, inseamCm;
  final String? fitPreference; // slim | regular | relaxed | oversized
  final List<String> styles;
  final List<String> colors;
  final List<String> occasions;
  final List<String> dislikedCuts;

  const StyleProfile({
    this.heightCm,
    this.build,
    this.shoeSize,
    this.shoulderCm,
    this.waistCm,
    this.hipCm,
    this.inseamCm,
    this.fitPreference,
    this.styles = const [],
    this.colors = const [],
    this.occasions = const [],
    this.dislikedCuts = const [],
  });

  static const empty = StyleProfile();

  StyleProfile copyWith({
    int? heightCm,
    String? build,
    String? shoeSize,
    int? shoulderCm,
    int? waistCm,
    int? hipCm,
    int? inseamCm,
    String? fitPreference,
    List<String>? styles,
    List<String>? colors,
    List<String>? occasions,
    List<String>? dislikedCuts,
  }) {
    return StyleProfile(
      heightCm: heightCm ?? this.heightCm,
      build: build ?? this.build,
      shoeSize: shoeSize ?? this.shoeSize,
      shoulderCm: shoulderCm ?? this.shoulderCm,
      waistCm: waistCm ?? this.waistCm,
      hipCm: hipCm ?? this.hipCm,
      inseamCm: inseamCm ?? this.inseamCm,
      fitPreference: fitPreference ?? this.fitPreference,
      styles: styles ?? this.styles,
      colors: colors ?? this.colors,
      occasions: occasions ?? this.occasions,
      dislikedCuts: dislikedCuts ?? this.dislikedCuts,
    );
  }

  /// Local persistence shape (flat, lossless).
  Map<String, dynamic> toStorageJson() => {
        'heightCm': heightCm,
        'build': build,
        'shoeSize': shoeSize,
        'shoulderCm': shoulderCm,
        'waistCm': waistCm,
        'hipCm': hipCm,
        'inseamCm': inseamCm,
        'fitPreference': fitPreference,
        'styles': styles,
        'colors': colors,
        'occasions': occasions,
        'dislikedCuts': dislikedCuts,
      };

  factory StyleProfile.fromStorageJson(Map<String, dynamic> j) {
    List<String> list(dynamic v) =>
        (v as List?)?.map((e) => e.toString()).toList() ?? const [];
    return StyleProfile(
      heightCm: j['heightCm'] as int?,
      build: j['build'] as String?,
      shoeSize: j['shoeSize'] as String?,
      shoulderCm: j['shoulderCm'] as int?,
      waistCm: j['waistCm'] as int?,
      hipCm: j['hipCm'] as int?,
      inseamCm: j['inseamCm'] as int?,
      fitPreference: j['fitPreference'] as String?,
      styles: list(j['styles']),
      colors: list(j['colors']),
      occasions: list(j['occasions']),
      dislikedCuts: list(j['dislikedCuts']),
    );
  }

  /// API context shape matching SDD §7 (omits empty fields to keep the prompt clean).
  /// Returns null when the profile carries no signal.
  Map<String, dynamic>? toApiJson() {
    final body = <String, dynamic>{};
    void put(String k, dynamic v) {
      if (v != null) body[k] = v;
    }

    put('heightCm', heightCm);
    put('build', build);
    put('shoeSize', shoeSize);
    put('shoulderCm', shoulderCm);
    put('waistCm', waistCm);
    put('hipCm', hipCm);
    put('inseamCm', inseamCm);

    final style = <String, dynamic>{};
    if (styles.isNotEmpty) style['styles'] = styles;
    if (colors.isNotEmpty) style['colors'] = colors;
    if (occasions.isNotEmpty) style['occasions'] = occasions;
    if (dislikedCuts.isNotEmpty) style['dislikedCuts'] = dislikedCuts;

    final out = <String, dynamic>{};
    if (body.isNotEmpty) out['body'] = body;
    if (fitPreference != null) out['fitPreference'] = fitPreference;
    if (style.isNotEmpty) out['style'] = style;

    return out.isEmpty ? null : out;
  }
}
