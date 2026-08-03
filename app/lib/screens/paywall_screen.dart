import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../services/analytics.dart';
import '../services/api_client.dart' show ApiException;
import '../theme.dart';
import '../widgets/wordmark.dart';

/// Subscription paywall. Two tiers (Monthly $12.99 / Yearly $89.99). Presented
/// when the 10-review free trial is exhausted (SDD §8). Purchase is stubbed —
/// real IAP runs through RevenueCat (SDD §8.1) once wired.
class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key, this.initialPlan = 1});
  /// 0 = Premium monthly, 1 = Pro yearly (default: best value), 2 = Pro
  /// monthly. Premium-feature upsells (fit controls) open with 0 preselected.
  final int initialPlan;
  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  // 0 = Premium monthly, 1 = Pro yearly (default: best value), 2 = Pro monthly.
  late int _plan = widget.initialPlan;
  bool _promoOpen = false;

  @override
  void initState() {
    super.initState();
    Analytics.paywallViewed();
  }

  bool _redeeming = false;
  final _promoCtl = TextEditingController();

  @override
  void dispose() {
    _promoCtl.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    final code = _promoCtl.text.trim();
    if (code.isEmpty || _redeeming) return;
    setState(() => _redeeming = true);
    try {
      final ent = await ref.read(looktokApiProvider).redeemPromoCode(code);
      Analytics.promoRedeemed(code: code.toUpperCase());
      ref.invalidate(entitlementProvider); // paywall gate re-reads the server
      if (!mounted) return;
      final pro = ent['pro'] == true;
      final left = ent['freeRemaining'];
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(pro
            ? 'Code applied — unlimited unlocked. Welcome aboard!'
            : 'Code applied — $left free looks on your account.'),
      ));
      Navigator.pop(context);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _redeeming = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _redeeming = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn\'t redeem the code — check your connection.')),
      );
    }
  }

  /// "Have a promo code?" → a sleek inline field, no extra screen.
  Widget _promoSection() {
    if (!_promoOpen) {
      return Center(
        child: TextButton(
          onPressed: () => setState(() => _promoOpen = true),
          child: const Text('Have a promo code?',
              style: TextStyle(color: AppColors.muted, fontSize: 13)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _promoCtl,
            autofocus: true,
            enabled: !_redeeming,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _redeem(),
            style: const TextStyle(
                fontWeight: FontWeight.w700, letterSpacing: 1.5, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'PROMO CODE',
              hintStyle: const TextStyle(
                  color: AppColors.muted, letterSpacing: 1.5, fontSize: 13),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              filled: true,
              fillColor: AppColors.bg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: AppColors.signature, width: 1.5),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 42,
          child: FilledButton(
            onPressed: _redeeming ? null : _redeem,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.pill)),
            ),
            child: _redeeming
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('Apply'),
          ),
        ),
      ]),
    );
  }

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
              const _Perk(text: 'Unlimited honest reviews & looks'),
              const _Perk(text: 'Compare two looks side by side'),
              const _Perk(text: 'Brand picks to shop later'),
              const Spacer(),
              _PlanTile(
                selected: _plan == 0,
                title: 'Premium',
                price: '\$19.99',
                unit: '/mo',
                note: 'Fit controls + accessory studio + everything in Pro',
                onTap: () => setState(() => _plan = 0),
              ),
              const SizedBox(height: 10),
              _PlanTile(
                selected: _plan == 1,
                title: 'Pro · Yearly',
                price: '\$89.99',
                unit: '/year',
                note: 'Best value · ~\$7.50/mo',
                onTap: () => setState(() => _plan = 1),
              ),
              const SizedBox(height: 10),
              _PlanTile(
                selected: _plan == 2,
                title: 'Pro · Monthly',
                price: '\$12.99',
                unit: '/mo',
                onTap: () => setState(() => _plan = 2),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  // Stub — RevenueCat purchase flow lands here (SDD §8.1).
                  // When it does, fire this AFTER the store confirms:
                  const plans = ['premium_monthly', 'pro_yearly', 'pro_monthly'];
                  const prices = [19.99, 89.99, 12.99];
                  Analytics.subscriptionPurchased(
                      plan: plans[_plan], revenue: prices[_plan]);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Subscribe ${plans[_plan]} — coming soon')),
                  );
                },
                child: Text(switch (_plan) {
                  0 => 'Start Premium — \$19.99/mo',
                  1 => 'Start Pro — \$89.99/year',
                  _ => 'Start Pro — \$12.99/mo',
                }),
              ),
              const SizedBox(height: 6),
              _promoSection(),
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
