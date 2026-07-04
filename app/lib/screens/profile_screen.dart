import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theme.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  static const _builds = ['slim', 'average', 'athletic', 'curvy', 'plus'];
  static const _fits = ['slim', 'regular', 'relaxed', 'oversized'];

  late final TextEditingController _height;
  late final TextEditingController _shoe;
  late final TextEditingController _styles;
  late final TextEditingController _colors;
  String? _build;
  String? _fit;

  @override
  void initState() {
    super.initState();
    final p = ref.read(profileProvider);
    _height = TextEditingController(text: p.heightCm?.toString() ?? '');
    _shoe = TextEditingController(text: p.shoeSize ?? '');
    _styles = TextEditingController(text: p.styles.join(', '));
    _colors = TextEditingController(text: p.colors.join(', '));
    _build = p.build;
    _fit = p.fitPreference;
  }

  @override
  void dispose() {
    _height.dispose();
    _shoe.dispose();
    _styles.dispose();
    _colors.dispose();
    super.dispose();
  }

  List<String> _csv(String s) => s
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  Future<void> _save() async {
    final p = ref.read(profileProvider).copyWith(
          heightCm: int.tryParse(_height.text.trim()),
          shoeSize: _shoe.text.trim().isEmpty ? null : _shoe.text.trim(),
          build: _build,
          fitPreference: _fit,
          styles: _csv(_styles.text),
          colors: _csv(_colors.text),
        );
    await ref.read(profileProvider.notifier).update(p);
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Profile saved')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          const Text(
            'Optional — the more you share, the sharper the advice on proportion and cut.',
            style: TextStyle(color: AppColors.muted, height: 1.4),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _height,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
                labelText: 'Height (cm)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          _dropdown('Build', _build, _builds, (v) => setState(() => _build = v)),
          const SizedBox(height: 16),
          _dropdown('Preferred fit', _fit, _fits, (v) => setState(() => _fit = v)),
          const SizedBox(height: 16),
          TextField(
            controller: _shoe,
            decoration: const InputDecoration(
                labelText: 'Shoe size (e.g. 43EU)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _styles,
            decoration: const InputDecoration(
                labelText: 'Styles you like (comma-separated)',
                hintText: 'minimal, smart-casual',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _colors,
            decoration: const InputDecoration(
                labelText: 'Colors you like (comma-separated)',
                hintText: 'navy, warm neutrals',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 28),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }

  Widget _dropdown(
    String label,
    String? value,
    List<String> options,
    ValueChanged<String?> onChanged,
  ) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      items: options
          .map((o) => DropdownMenuItem(value: o, child: Text(o)))
          .toList(),
      onChanged: onChanged,
    );
  }
}
