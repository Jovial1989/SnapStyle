import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../services/mask_generation.dart';
import '../theme.dart';

/// Hidden developer menu — reached by tapping the version line on the Profile
/// screen 7 times. Local overrides here BYPASS the Supabase remote flags
/// entirely; they live in SharedPreferences on this device only.
class DevSettingsScreen extends ConsumerStatefulWidget {
  const DevSettingsScreen({super.key});
  @override
  ConsumerState<DevSettingsScreen> createState() => _DevSettingsScreenState();
}

class _DevSettingsScreenState extends ConsumerState<DevSettingsScreen> {
  bool? _force; // local override switch
  bool? _remote; // what Supabase currently says (read-only display)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    final flags = ref.read(featureFlagServiceProvider);
    final force = await flags.forceSam2();
    final remote = await flags.remoteUseSam2(refresh: refresh);
    if (!mounted) return;
    setState(() {
      _force = force;
      _remote = remote;
    });
  }

  Future<void> _setForce(bool v) async {
    setState(() => _force = v);
    await ref.read(featureFlagServiceProvider).setForceSam2(v);
  }

  @override
  Widget build(BuildContext context) {
    final engineConfigured = Sam2MaskStrategy.configured;
    return Scaffold(
      appBar: AppBar(title: const Text('Developer settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          const Text('MASK ENGINE',
              style: TextStyle(
                  color: AppColors.muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 2)),
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Force Enable SAM 2 Engine (Override)',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            subtitle: const Text(
                'Bypasses the remote flag entirely on this device. '
                'Failures still fall back to the legacy cascade.'),
            value: _force ?? false,
            onChanged: _force == null ? null : _setForce,
          ),
          const Divider(height: 28),
          _row('Remote flag  ·  use_sam2_engine',
              _remote == null ? '…' : (_remote! ? 'ON' : 'OFF')),
          const SizedBox(height: 8),
          _row('SAM2_ENGINE_URL compiled in',
              engineConfigured ? Sam2MaskStrategy.engineUrl : '— not set (engine inert)'),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () => _load(refresh: true),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Refresh remote flag'),
          ),
          const SizedBox(height: 16),
          const Text(
            'Effective engine = override ON → SAM 2 · else remote flag → SAM 2 · '
            'else legacy cascade. Without a compiled SAM2_ENGINE_URL the '
            'experimental path is never attempted, whatever the flags say.',
            style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(child: Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 13))),
        const SizedBox(width: 12),
        Flexible(
          child: Text(value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ),
      ],
    );
  }
}
