/// Who a photo is of — the account owner ("me") or an ad-hoc guest (SDD §14.10).
///
/// Guests are EPHEMERAL: their height/measurements live only for this flow and
/// are never saved to the owner's profile. A name is captured only when a look
/// or review is saved, so history can read "Victoria's look" instead of yours.
class Subject {
  final bool isMe;
  final String? name; // guest name — captured at save time, not before
  final int? heightCm;
  final int? bustCm, waistCm, hipCm; // optional guest measurements (point cm)
  final String? bodyType, proportionDesc; // seeded from the AI estimate

  const Subject.me()
      : isMe = true,
        name = null,
        heightCm = null,
        bustCm = null,
        waistCm = null,
        hipCm = null,
        bodyType = null,
        proportionDesc = null;

  const Subject.guest({
    required this.heightCm,
    this.bustCm,
    this.waistCm,
    this.hipCm,
    this.bodyType,
    this.proportionDesc,
    this.name,
  }) : isMe = false;

  bool get isGuest => !isMe;

  /// A copy of this guest carrying [n] as the name (owner is returned unchanged).
  Subject withName(String? n) => isMe
      ? this
      : Subject.guest(
          heightCm: heightCm,
          bustCm: bustCm,
          waistCm: waistCm,
          hipCm: hipCm,
          bodyType: bodyType,
          proportionDesc: proportionDesc,
          name: n,
        );

  static Map<String, dynamic>? _range(int? v) =>
      v == null ? null : {'min': v, 'max': v};

  /// The `body_profile` override sent to analyze / generate-look for a guest.
  /// Null for the owner (server falls back to their stored profile).
  Map<String, dynamic>? toOverride() {
    if (isMe) return null;
    final measures = <String, dynamic>{
      if (_range(bustCm) != null) 'chest_cm': _range(bustCm),
      if (_range(waistCm) != null) 'waist_cm': _range(waistCm),
      if (_range(hipCm) != null) 'hip_cm': _range(hipCm),
    };
    return {
      if (heightCm != null) 'height_cm': heightCm,
      if (bodyType != null) 'body_type': bodyType,
      if (proportionDesc != null) 'proportions': {'description': proportionDesc},
      if (measures.isNotEmpty) 'estimated_measurements': measures,
    };
  }
}
