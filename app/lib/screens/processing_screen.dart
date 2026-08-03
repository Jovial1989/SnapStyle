import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/styling_loader.dart';
import '../widgets/scan_loader.dart';

/// Wrapper returned via Navigator.pop when the task fails.
class ProcessingError {
  final String message;
  ProcessingError(this.message);
}

/// Full-screen "AI is working" state. Runs [task] while showing a soft circular
/// progress ring around a selfie figure + rotating status lines, then pops with
/// the resolved value (or a [ProcessingError]). Reused by critique + onboarding.
class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({super.key, required this.task, required this.messages, this.scanImage});
  final Future<dynamic> task;
  final List<String> messages;

  /// When set (Review flow), the loader is the user's OWN photo with a scanning
  /// animation — not stock imagery. Null → plain ring loader.
  final Uint8List? scanImage;

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  @override
  void initState() {
    super.initState();
    widget.task.then((v) {
      if (mounted) Navigator.of(context).pop(v);
    }).catchError((e) {
      if (mounted) Navigator.of(context).pop(ProcessingError(e.toString()));
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.scanImage != null) {
      // Scanner owns the whole screen (photo is full-bleed, dark register).
      return Scaffold(
        backgroundColor: Colors.black,
        body: ScanLoader(image: widget.scanImage!, messages: widget.messages),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(child: StylingLoader(messages: widget.messages)),
    );
  }
}
