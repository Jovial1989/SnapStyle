import 'package:flutter/material.dart';
import '../theme.dart';

/// "In your closet" — minimalist badge overlaid on item cards whenever the AI
/// used / suggests a piece the user already owns. `compact` = icon-only (for
/// tiny thumbnails); full = hanger + label.
class ClosetBadge extends StatelessWidget {
  const ClosetBadge({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 7, vertical: compact ? 4 : 3.5),
      decoration: BoxDecoration(
        color: AppColors.ink,
        borderRadius: BorderRadius.circular(compact ? 999 : 6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.checkroom, size: 10, color: Colors.white),
        if (!compact) ...[
          const SizedBox(width: 4),
          const Text('In your closet',
              style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
        ],
      ]),
    );
  }
}
