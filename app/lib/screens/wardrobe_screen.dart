import 'package:flutter/material.dart';
import '../theme.dart';

/// History / Digital Wardrobe tab. Placeholder empty state — past reviews +
/// scores land here in a later phase (retention loop).
class WardrobeScreen extends StatelessWidget {
  const WardrobeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wardrobe', style: AppType.h2)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.grid_view_outlined, size: 40, color: AppColors.muted),
              const SizedBox(height: 16),
              const Text('No looks yet', style: AppType.h2),
              const SizedBox(height: 8),
              const Text(
                'Your reviewed outfits and their scores will collect here.',
                textAlign: TextAlign.center,
                style: AppType.body,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
