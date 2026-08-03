import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../theme.dart';

/// Result of the Stylist Portal: the occasion text, whether to use the user's
/// own wardrobe (`closet`), an optional freshly-picked photo (`photo`) to
/// style — falls back to the profile photo when null — and `digitize`, set
/// when the user picked the wardrobe source without enough digitized clothes:
/// the caller should open the wardrobe screen instead of generating.
typedef PortalResult = ({String text, bool closet, XFile? photo, bool digitize});

/// Unified "What should I wear?" entry — a glass bottom sheet with a custom
/// occasion field, quick chips, and two explicit source cards (My wardrobe /
/// Fresh ideas). Copy is deliberately plain-spoken (SDD §14.3). Pops a
/// [PortalResult] or null. [wardrobeCount] feeds the wardrobe card's state.
Future<PortalResult?> openStylistPortal(BuildContext context,
    {List<String> recent = const [], Future<int>? wardrobeCount}) {
  return showModalBottomSheet<PortalResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _StylistPortal(recent: recent, wardrobeCount: wardrobeCount),
  );
}

const _chips = ['Office', 'Date', 'Drinks', 'Casual', 'Active', 'Hot day'];

class _StylistPortal extends StatefulWidget {
  const _StylistPortal({this.recent = const [], this.wardrobeCount});
  final List<String> recent;
  final Future<int>? wardrobeCount;
  @override
  State<_StylistPortal> createState() => _StylistPortalState();
}

/// Minimum digitized items for wardrobe-only looks — below this the wardrobe
/// card turns into a "digitize your wardrobe" action (a top + a bottom is the
/// smallest outfit the planner can assemble).
const _kMinWardrobe = 2;

class _StylistPortalState extends State<_StylistPortal> {
  final _text = TextEditingController();
  bool _closet = false;
  bool _canGo = false;
  XFile? _photo;
  int? _wardrobe; // null = still counting

  @override
  void initState() {
    super.initState();
    _text.addListener(() {
      final can = _text.text.trim().isNotEmpty;
      if (can != _canGo) setState(() => _canGo = can);
    });
    widget.wardrobeCount?.then((n) {
      if (mounted) setState(() => _wardrobe = n);
    }, onError: (_) {/* card just keeps its neutral subtitle */});
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _pickChip(String c) {
    _text.text = c;
    _text.selection = TextSelection.collapsed(offset: c.length);
    setState(() => _canGo = true);
  }

  void _go() {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    Navigator.of(context)
        .pop((text: t, closet: _closet, photo: _photo, digitize: false));
  }

  void _pickSource(bool closet) {
    HapticFeedback.selectionClick();
    // Wardrobe picked without enough digitized clothes → the honest move is
    // to go digitize, not to fake "your" looks from a near-empty closet.
    if (closet && _wardrobe != null && _wardrobe! < _kMinWardrobe) {
      Navigator.of(context)
          .pop((text: '', closet: true, photo: null, digitize: true));
      return;
    }
    setState(() => _closet = closet);
  }

  Future<void> _pickPhoto(ImageSource src) async {
    final f = await ImagePicker().pickImage(source: src, maxWidth: 800, maxHeight: 800, imageQuality: 80);
    if (f != null && mounted) setState(() => _photo = f);
  }

  void _photoSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined, color: AppColors.ink),
            title: const Text('Take a selfie', style: TextStyle(fontWeight: FontWeight.w600)),
            onTap: () { Navigator.pop(context); _pickPhoto(ImageSource.camera); },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined, color: AppColors.ink),
            title: const Text('Choose from gallery', style: TextStyle(fontWeight: FontWeight.w600)),
            onTap: () { Navigator.pop(context); _pickPhoto(ImageSource.gallery); },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    // Solid sheet — glass is reserved for photo overlays (D-2).
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.hero)),
      child: Container(
          decoration: const BoxDecoration(
            color: AppColors.bg,
            border: Border(top: BorderSide(color: Color(0x22000000))),
          ),
          padding: EdgeInsets.fromLTRB(24, 10, 24, 24 + bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 20),
              const Text('Where are you headed?', style: AppType.h2),
              const SizedBox(height: 16),
              // Borderless field — a faint bottom rule, not an HTML box.
              TextField(
                controller: _text,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _go(),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                cursorColor: AppColors.signature,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Type it — e.g. dinner date, beach day',
                  hintStyle: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w400, fontSize: 18),
                  border: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.line)),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.line)),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.ink, width: 2)),
                  contentPadding: EdgeInsets.only(bottom: 8),
                ),
              ),
              if (widget.recent.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text('RECENT',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.4, color: AppColors.muted)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.recent.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final r = widget.recent[i];
                      return GestureDetector(
                        onTap: () => _pickChip(r),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(AppRadius.control),
                            border: Border.all(color: AppColors.line),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.history, size: 13, color: AppColors.muted),
                            const SizedBox(width: 6),
                            Text(r, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                height: 36,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _chips.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final c = _chips[i];
                    final on = _text.text.trim() == c;
                    return GestureDetector(
                      onTap: () => _pickChip(c),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: on ? AppColors.ink : Colors.white,
                          borderRadius: BorderRadius.circular(AppRadius.control),
                          border: Border.all(color: on ? AppColors.ink : AppColors.line),
                        ),
                        child: Text(c,
                            style: TextStyle(
                                color: on ? Colors.white : AppColors.ink,
                                fontWeight: FontWeight.w600,
                                fontSize: 14)),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 18),
              // Photo to style — a fresh selfie, or fall back to the profile photo.
              GestureDetector(
                onTap: _photoSheet,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: Row(children: [
                    if (_photo != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(File(_photo!.path), width: 40, height: 50, fit: BoxFit.cover),
                      )
                    else
                      Container(
                        width: 40, height: 50,
                        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8)),
                        child: const Icon(Icons.add_a_photo_outlined, size: 18, color: AppColors.signature),
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_photo != null ? 'Your selfie' : 'Add a selfie',
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                          const SizedBox(height: 2),
                          Text(_photo != null ? 'Tap to change' : 'Or we’ll use your profile photo',
                              style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: AppColors.muted),
                  ]),
                ),
              ),
              const SizedBox(height: 18),
              // Two explicit sources — the wardrobe is the hero option; short
              // on digitized clothes it becomes the "digitize" action instead.
              Row(children: [
                Expanded(
                  child: _SourceCard(
                    icon: Icons.checkroom,
                    title: 'My wardrobe',
                    subtitle: switch (_wardrobe) {
                      null => 'Only clothes you own',
                      < _kMinWardrobe => 'Digitize your clothes first',
                      final n => 'From your $n digitized items',
                    },
                    selected: _closet,
                    action: _wardrobe != null && _wardrobe! < _kMinWardrobe,
                    onTap: () => _pickSource(true),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _SourceCard(
                    icon: Icons.auto_awesome,
                    title: 'Fresh ideas',
                    subtitle: 'New pieces, not from your closet',
                    selected: !_closet,
                    onTap: () => _pickSource(false),
                  ),
                ),
              ]),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _canGo ? _go : null,
                  icon: const Icon(Icons.auto_awesome, size: 18, color: AppColors.signature),
                  label: const Text('Style me'),
                ),
              ),
            ],
          ),
        ),
    );
  }
}

/// Source card: white, ink border when selected; `action` renders the cobalt
/// "go digitize" state (arrow instead of a check, signature accents).
class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.action = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final bool action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final border = action
        ? AppColors.signature
        : selected
            ? AppColors.ink
            : AppColors.line;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border, width: selected || action ? 1.6 : 1),
          boxShadow: selected
              ? const [BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 3))]
              : const [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18,
                  color: action ? AppColors.signature : AppColors.ink),
              const Spacer(),
              if (action)
                const Icon(Icons.arrow_forward, size: 16, color: AppColors.signature)
              else if (selected)
                const Icon(Icons.check_circle, size: 16, color: AppColors.ink),
            ]),
            const SizedBox(height: 10),
            Text(title,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
            const SizedBox(height: 3),
            Text(subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: action ? AppColors.signature : AppColors.muted,
                    fontSize: 11.5,
                    fontWeight: action ? FontWeight.w600 : FontWeight.w400)),
          ],
        ),
      ),
    );
  }
}
