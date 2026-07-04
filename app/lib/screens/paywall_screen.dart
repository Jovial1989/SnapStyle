import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/wordmark.dart';

/// Subscription paywall. Two tiers (Monthly $12.99 / Yearly $89.99). Presented
/// when the 10-review free trial is exhausted (SDD §8). Purchase is stubbed —
/// real IAP runs through RevenueCat (SDD §8.1) once wired.
class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key});
  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  bool _yearly = true; // default to the better-value plan

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  icon: const Icon(Icons.close, color: AppColors.ink),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              const Logo(size: 20),
              const SizedBox(height: 28),
              const Text('Unlimited\nstyle reviews.', style: AppType.display),
              const SizedBox(height: 14),
              const _Perk(text: 'Honest AI reviews on every outfit'),
              const _Perk(text: 'Look suggestions & body-profile advice'),
              const _Perk(text: 'Build outfits from your wardrobe'),
              const Spacer(),
              _PlanTile(
                selected: _yearly,
                title: 'Yearly',
                price: '\$89.99',
                unit: '/year',
                note: 'Best value · ~\$7.50/mo',
                onTap: () => setState(() => _yearly = true),
              ),
              const SizedBox(height: 10),
              _PlanTile(
                selected: !_yearly,
                title: 'Monthly',
                price: '\$12.99',
                unit: '/mo',
                onTap: () => setState(() => _yearly = false),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  // Stub — RevenueCat purchase flow lands here (SDD §8.1).
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Subscribe ${_yearly ? "Yearly" : "Monthly"} — coming soon')),
                  );
                },
                child: Text(_yearly ? 'Start — \$89.99/year' : 'Start — \$12.99/mo'),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: () {},
                  child: const Text('Restore purchases', style: TextStyle(color: AppColors.muted)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Perk extends StatelessWidget {
  const _Perk({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Icon(Icons.check, size: 18, color: AppColors.signature),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: AppType.body)),
        ],
      ),
    );
  }
}

class _PlanTile extends StatelessWidget {
  const _PlanTile({
    required this.selected,
    required this.title,
    required this.price,
    required this.unit,
    required this.onTap,
    this.note,
  });
  final bool selected;
  final String title, price, unit;
  final String? note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: selected ? AppColors.ink : AppColors.bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? AppColors.ink : AppColors.line, width: selected ? 2 : 1),
        ),
        child: Row(
          children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 20, color: selected ? AppColors.signature : AppColors.muted),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          color: selected ? Colors.white : AppColors.ink)),
                  if (note != null)
                    Text(note!,
                        style: TextStyle(
                            fontSize: 12,
                            color: selected ? Colors.white70 : AppColors.muted)),
                ],
              ),
            ),
            RichText(
              text: TextSpan(
                style: TextStyle(color: selected ? Colors.white : AppColors.ink),
                children: [
                  TextSpan(text: price, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  TextSpan(
                      text: unit,
                      style: TextStyle(
                          fontSize: 13,
                          color: selected ? Colors.white70 : AppColors.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
