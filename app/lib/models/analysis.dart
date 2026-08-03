/// A look suggestion shown in the pin carousel. `imageUrl` is filled by OUR
/// backend after generating from `prompt` (fal); null until then → placeholder.
/// No shop/buy — inspiration only (SDD §1.3).
class VisualSuggestion {
  final String prompt;
  final String caption;
  final String? altText;
  final String? imageUrl;

  const VisualSuggestion({
    required this.prompt,
    required this.caption,
    this.altText,
    this.imageUrl,
  });

  factory VisualSuggestion.fromJson(Map<String, dynamic> j) => VisualSuggestion(
        prompt: (j['prompt'] ?? '').toString(),
        caption: (j['caption'] ?? '').toString(),
        altText: j['alt_text']?.toString(),
        imageUrl: j['image_url']?.toString(),
      );
}

/// Mirrors ANALYSIS_SCHEMA (v2, hotspots) returned by the backend (SDD §5.4).
class Hotspot {
  final double xPercent; // 0..100, left→right
  final double yPercent; // 0..100, top→bottom
  final String area;
  final String severity; // issue | tip | good
  final String title;
  final String detail;
  final String? fix;
  final List<VisualSuggestion> suggestions;

  const Hotspot({
    required this.xPercent,
    required this.yPercent,
    required this.area,
    required this.severity,
    required this.title,
    required this.detail,
    this.fix,
    this.suggestions = const [],
  });

  factory Hotspot.fromJson(Map<String, dynamic> j) {
    double num0(dynamic v) => (v is num) ? v.toDouble().clamp(0, 100) : 0;
    return Hotspot(
      xPercent: num0(j['x_percent']),
      yPercent: num0(j['y_percent']),
      area: (j['area'] ?? '').toString(),
      severity: (j['severity'] ?? 'tip').toString(),
      title: (j['title'] ?? '').toString(),
      detail: (j['detail'] ?? '').toString(),
      fix: (j['fix'] as String?)?.trim().isEmpty ?? true ? null : j['fix'].toString(),
      suggestions: ((j['visual_suggestions'] as List?) ?? const [])
          .map((e) => VisualSuggestion.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }
}

class AnalysisResult {
  final bool analyzable;
  final String? note;
  final String overallSummary;
  final int overallScore;
  final List<Hotspot> hotspots;
  final String model;
  final String promptVersion;
  final String? generationId; // history row id (for tagging a guest name on save)

  const AnalysisResult({
    required this.analyzable,
    this.note,
    required this.overallSummary,
    required this.overallScore,
    required this.hotspots,
    required this.model,
    required this.promptVersion,
    this.generationId,
  });

  /// Defensive: model should return 1–10, but if it emits a 0–100 value,
  /// normalize it so the "/10" badge never shows "75/10".
  static int _score(dynamic v) {
    if (v is! num) return 0;
    var s = v.round();
    if (s > 10) s = (s / 10).round();
    return s.clamp(0, 10);
  }

  factory AnalysisResult.fromResponse(Map<String, dynamic> res) {
    final a = (res['analysis'] as Map).cast<String, dynamic>();
    final overall = (a['overall'] as Map?)?.cast<String, dynamic>() ?? const {};
    return AnalysisResult(
      analyzable: a['analyzable'] == true,
      note: a['note']?.toString(),
      overallSummary: (overall['summary'] ?? '').toString(),
      overallScore: _score(overall['score']),
      hotspots: ((a['hotspots'] as List?) ?? const [])
          .map((e) => Hotspot.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      model: (res['model'] ?? '').toString(),
      promptVersion: (res['promptVersion'] ?? '').toString(),
      generationId: res['generationId']?.toString(),
    );
  }
}
