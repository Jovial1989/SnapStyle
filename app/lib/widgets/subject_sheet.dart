import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/subject.dart';
import '../providers.dart';
import '../theme.dart';

/// "Whose look is this?" — asked before any photo upload so we style/read for the
/// right person (SDD §14.10). Returns a [Subject]: the owner, a guest (with a
/// required height + optional AI-estimated measurements), or null if cancelled.
Future<Subject?> askSubject(BuildContext context, WidgetRef ref, {required Uint8List photoBytes}) async {
  final me = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    backgroundColor: AppColors.bg,
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 4, 24, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Who is this look for?', style: AppType.h2),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.person_outline, color: AppColors.ink),
            title: const Text("It's me", style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Use my saved profile'),
            onTap: () => Navigator.pop(context, true),
          ),
          ListTile(
            leading: const Icon(Icons.group_outlined, color: AppColors.ink),
            title: const Text('Someone else', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Style for a friend — add their height'),
            onTap: () => Navigator.pop(context, false),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (me == null) return null; // cancelled
  if (me) return const Subject.me();
  if (!context.mounted) return null;
  return showModalBottomSheet<Subject>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.bg,
    builder: (_) => _GuestSheet(photoBytes: photoBytes),
  );
}

/// Ask for the guest's name at save time so history reads "Victoria's look".
/// Returns the trimmed name, or null if cancelled.
Future<String?> promptSubjectName(BuildContext context, {String? initial}) {
  final ctrl = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Whose look is this?'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Victoria'),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, ctrl.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

class _GuestSheet extends ConsumerStatefulWidget {
  const _GuestSheet({required this.photoBytes});
  final Uint8List photoBytes;
  @override
  ConsumerState<_GuestSheet> createState() => _GuestSheetState();
}

class _GuestSheetState extends ConsumerState<_GuestSheet> {
  final _height = TextEditingController();
  final _bust = TextEditingController();
  final _waist = TextEditingController();
  final _hip = TextEditingController();
  String? _bodyType, _proportionDesc, _error;
  bool _estimating = false;

  @override
  void dispose() {
    for (final c in [_height, _bust, _waist, _hip]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _cm(TextEditingController c) => int.tryParse(c.text.trim());

  Future<void> _estimate() async {
    final h = _cm(_height);
    if (h == null || h < 100 || h > 250) {
      setState(() => _error = 'Enter a height between 100 and 250 cm first');
      return;
    }
    if (!ref.read(cloudEnabledProvider)) {
      setState(() => _error = 'Estimating needs the cloud build');
      return;
    }
    setState(() {
      _error = null;
      _estimating = true;
    });
    try {
      final api = ref.read(looktokApiProvider);
      final path = await api.uploadPhoto(widget.photoBytes);
      final p = await api.onboardingProfile(photoPath: path, heightCm: h, ephemeral: true);
      int? mid(num? a, num? b) => (a == null || b == null) ? null : ((a + b) / 2).round();
      if (!mounted) return;
      setState(() {
        _bodyType = p.bodyType;
        _proportionDesc = p.proportionDescription;
        final b = mid(p.chest.min, p.chest.max);
        final w = mid(p.waist.min, p.waist.max);
        final hp = mid(p.hip.min, p.hip.max);
        if (b != null) _bust.text = '$b';
        if (w != null) _waist.text = '$w';
        if (hp != null) _hip.text = '$hp';
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not estimate — enter measurements manually');
    } finally {
      if (mounted) setState(() => _estimating = false);
    }
  }

  void _continue() {
    final h = _cm(_height);
    if (h == null || h < 100 || h > 250) {
      setState(() => _error = 'Height is required (100–250 cm)');
      return;
    }
    Navigator.pop(
      context,
      Subject.guest(
        heightCm: h,
        bustCm: _cm(_bust),
        waistCm: _cm(_waist),
        hipCm: _cm(_hip),
        bodyType: _bodyType,
        proportionDesc: _proportionDesc,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 4, 24, 24 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Their details', style: AppType.h2),
            const SizedBox(height: 4),
            const Text('Height is required. The rest sharpens the read — leave blank to skip.',
                style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4)),
            const SizedBox(height: 18),
            _NumField(controller: _height, label: 'Height', required: true, error: _error),
            const SizedBox(height: 18),
            Row(children: [
              const Text('Measurements (optional)',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              const Spacer(),
              TextButton.icon(
                onPressed: _estimating ? null : _estimate,
                icon: _estimating
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome, size: 16, color: AppColors.signature),
                label: Text(_estimating ? 'Reading…' : 'Estimate from photo'),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _NumField(controller: _bust, label: 'Bust')),
              const SizedBox(width: 12),
              Expanded(child: _NumField(controller: _waist, label: 'Waist')),
              const SizedBox(width: 12),
              Expanded(child: _NumField(controller: _hip, label: 'Hip')),
            ]),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _continue, child: const Text('Continue')),
            ),
          ],
        ),
      ),
    );
  }
}

class _NumField extends StatelessWidget {
  const _NumField({required this.controller, required this.label, this.required = false, this.error});
  final TextEditingController controller;
  final String label;
  final bool required;
  final String? error;
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: required ? '$label *' : label,
        suffixText: 'cm',
        errorText: required ? error : null,
      ),
    );
  }
}
