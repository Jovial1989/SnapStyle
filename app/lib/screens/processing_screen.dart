import 'dart:async';
import 'package:flutter/material.dart';
import '../theme.dart';

/// Wrapper returned via Navigator.pop when the task fails.
class ProcessingError {
  final String message;
  ProcessingError(this.message);
}

/// Full-screen "AI is working" state. Runs [task] while showing a scanning
/// animation over a silhouette + rotating status lines, then pops with the
/// resolved value (or a [ProcessingError]). Reused by critique + onboarding.
class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({super.key, required this.task, required this.messages});
  final Future<dynamic> task;
  final List<String> messages;

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scan =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
  Timer? _rotator;
  int _msg = 0;

  @override
  void initState() {
    super.initState();
    _rotator = Timer.periodic(const Duration(milliseconds: 1300), (_) {
      if (mounted) setState(() => _msg = (_msg + 1) % widget.messages.length);
    });
    widget.task.then((v) {
      if (mounted) Navigator.of(context).pop(v);
    }).catchError((e) {
      if (mounted) Navigator.of(context).pop(ProcessingError(e.toString()));
    });
  }

  @override
  void dispose() {
    _scan.dispose();
    _rotator?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 220,
                height: 340,
                child: AnimatedBuilder(
                  animation: _scan,
                  builder: (_, _) => CustomPaint(painter: _ScanPainter(_scan.value)),
                ),
              ),
              const SizedBox(height: 44),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: Text(
                  widget.messages[_msg],
                  key: ValueKey(_msg),
                  style: AppType.h2,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 10),
              const Text('Reading the full picture…', style: AppType.body),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanPainter extends CustomPainter {
  _ScanPainter(this.t);
  final double t; // 0..1

  @override
  void paint(Canvas canvas, Size s) {
    final cx = s.width / 2;
    final headR = s.width * 0.11;
    final bodyTop = headR * 2 + 12;
    final bodyW = s.width * 0.46;

    // Clean centered full-body silhouette (head + shoulders taper into a capsule).
    final path = Path()
      ..addOval(Rect.fromCircle(center: Offset(cx, headR + 4), radius: headR));
    path.addRRect(RRect.fromRectAndCorners(
      Rect.fromLTRB(cx - bodyW / 2, bodyTop, cx + bodyW / 2, s.height),
      topLeft: Radius.circular(bodyW * 0.5),
      topRight: Radius.circular(bodyW * 0.5),
      bottomLeft: const Radius.circular(28),
      bottomRight: const Radius.circular(28),
    ));

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = AppColors.line,
    );

    // Sweeping scan band + line, clipped to the silhouette so it reads as a scan.
    canvas.save();
    canvas.clipPath(path);
    final y = t * s.height;
    final band = Rect.fromLTWH(0, y - 30, s.width, 60);
    canvas.drawRect(
      band,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x000A0A0A), Color(0x1F0A0A0A), Color(0x000A0A0A)],
        ).createShader(band),
    );
    canvas.drawLine(
      Offset(0, y),
      Offset(s.width, y),
      Paint()
        ..color = AppColors.ink
        ..strokeWidth = 1.5,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ScanPainter old) => old.t != t;
}
