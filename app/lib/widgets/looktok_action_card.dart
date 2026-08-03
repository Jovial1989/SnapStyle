import 'package:flutter/material.dart';

import '../theme.dart';

/// The Home hub's standardized action card — ONE widget for every entry so
/// padding, type, icon plates and the trailing chevron can never drift apart.
///
/// `primary: true`  → the stark black hero card (soft drop shadow + a faint
///                    cobalt under-glow so it reads tactile, not flat).
/// `primary: false` → pure white, radius 20, Apple-grade diffuse shadow
///                    (blur 24, spread 0, black 4%).
class LooktokActionCard extends StatelessWidget {
  const LooktokActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 22, vertical: primary ? 28 : 22),
        decoration: BoxDecoration(
          color: primary ? AppColors.ink : Colors.white,
          borderRadius: BorderRadius.circular(primary ? AppRadius.hero : 20),
          boxShadow: primary
              ? [
                  const BoxShadow(
                      color: Color(0x3D000000), blurRadius: 28, offset: Offset(0, 12)),
                  BoxShadow(
                      color: AppColors.signature.withValues(alpha: 0.16),
                      blurRadius: 36,
                      offset: const Offset(0, 6)),
                ]
              : const [
                  BoxShadow(
                      color: Color(0x0A000000), blurRadius: 24, spreadRadius: 0,
                      offset: Offset(0, 8)),
                ],
        ),
        child: Row(children: [
          Icon(icon, size: 26, color: primary ? AppColors.signature : AppColors.ink),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: primary ? 20 : 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                        color: primary ? Colors.white : AppColors.ink)),
                const SizedBox(height: 3),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        color: primary ? Colors.white70 : AppColors.muted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.chevron_right,
              size: 20, color: primary ? Colors.white70 : AppColors.muted),
        ]),
      ),
    );
  }
}
