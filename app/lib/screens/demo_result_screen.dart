import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/analysis.dart';
import 'look_editor_screen.dart';

/// Marketing-only harness: renders the real post-review editor with a bundled
/// photo + a captured analysis payload, to screenshot the app's actual flow.
/// Enabled via --dart-define=DEMO=result. Not part of any user flow.
class DemoResultScreen extends StatelessWidget {
  const DemoResultScreen({super.key, this.restyle = false});
  final bool restyle; // capture the post-swap "restyle" state instead of the read

  Future<(AnalysisResult, dynamic)> _load() async {
    final bytes = (await rootBundle.load('assets/demo/fit.jpg')).buffer.asUint8List();
    final json = jsonDecode(await rootBundle.loadString('assets/demo/fit.json')) as Map<String, dynamic>;
    return (AnalysisResult.fromResponse(json), bytes);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(AnalysisResult, dynamic)>(
      future: _load(),
      builder: (_, snap) {
        if (!snap.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final (result, bytes) = snap.data!;
        return LookEditorScreen(
            imageBytes: bytes, analysis: result, score: result.overallScore, demoPickRecommended: restyle);
      },
    );
  }
}
