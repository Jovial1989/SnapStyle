import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../models/wardrobe_item.dart';
import '../providers.dart';
import '../services/native_looktok_engine.dart';
import '../services/photo_validator.dart';
import '../services/smart_image_processing.dart';
import '../theme.dart';
import '../widgets/premium_wardrobe_loader.dart';
import 'wardrobe_item_detail_screen.dart';

/// Digital Wardrobe: the clothes you own. Add pieces (AI auto-labels them);
/// "My clothes" in the Stylist Portal builds looks from these. Cloud-only.
class WardrobeItemsScreen extends ConsumerStatefulWidget {
  const WardrobeItemsScreen({super.key});
  @override
  ConsumerState<WardrobeItemsScreen> createState() => _WardrobeItemsScreenState();
}

class _WardrobeItemsScreenState extends ConsumerState<WardrobeItemsScreen> {
  Future<List<Map<String, dynamic>>>? _future;
  bool _adding = false;
  // Categorized closet tabs. 'all' first; keys match wardrobe_items.category.
  static const _tabs = [('all', 'All'), ('top', 'Tops'), ('bottom', 'Bottoms'), ('shoes', 'Shoes'), ('outerwear', 'Outerwear'), ('accessory', 'Accessories')];
  String _tab = 'all';

  @override
  void initState() {
    super.initState();
    _future = ref.read(looktokApiProvider).wardrobeItems();
  }

  void _reload() => setState(() => _future = ref.read(looktokApiProvider).wardrobeItems());

  // Signed-URL futures memoized per path: without this every setState (tab
  // switch) minted NEW futures → every tile refetched + flashed. Stable futures
  // keep images on screen and off the network.
  final Map<String, Future<String>> _urls = {};
  Future<String> _url(String p) => _urls[p] ??= ref.read(looktokApiProvider).wardrobeImageUrl(p);

  // Intent-driven add: ask WHAT they're adding first (targeted extraction is
  // cheaper and more accurate), then where the photo comes from, then upload.
  Future<void> _add() async {
    // FIRST choice: add a WHOLE LOOK (every piece of one outfit, one after
    // another) or a single item. Whole-look is the primary path — it builds
    // the closet fastest from a photographed outfit.
    final whole = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.bg,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Add to your wardrobe', style: AppType.h2),
            const SizedBox(height: 4),
            const Text('Digitize a whole outfit, or just one piece.',
                style: TextStyle(color: AppColors.muted, fontSize: 13)),
            const SizedBox(height: 16),
            _AddModeCard(
              icon: Icons.checkroom_rounded,
              title: 'A whole look',
              caption: 'Add every piece of one outfit — top, bottom, shoes…',
              primary: true,
              onTap: () => Navigator.pop(context, true),
            ),
            const SizedBox(height: 10),
            _AddModeCard(
              icon: Icons.add_a_photo_outlined,
              title: 'A single item',
              caption: 'Add one specific piece.',
              primary: false,
              onTap: () => Navigator.pop(context, false),
            ),
          ]),
        ),
      ),
    );
    if (whole == null || !mounted) return;
    if (!whole) { await _addOneItem(); return; }
    // Whole look: loop the single-item add, counting pieces, until "Done".
    var added = 0;
    while (mounted) {
      final ok = await _addOneItem(pieceNumber: added + 1);
      if (!ok) break;
      added++;
      if (!mounted) return;
      final more = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: AppColors.bg,
        showDragHandle: true,
        builder: (_) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$added ${added == 1 ? 'piece' : 'pieces'} added',
                  style: AppType.h2),
              const SizedBox(height: 4),
              const Text('Add the next piece of this look?',
                  style: TextStyle(color: AppColors.muted, fontSize: 13)),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: _AddModeCard(
                  icon: Icons.add_rounded, title: 'Add another', caption: '',
                  primary: true, onTap: () => Navigator.pop(context, true))),
                const SizedBox(width: 10),
                Expanded(child: _AddModeCard(
                  icon: Icons.check_rounded, title: 'Done', caption: '',
                  primary: false, onTap: () => Navigator.pop(context, false))),
              ]),
            ]),
          ),
        ),
      );
      if (more != true) break;
    }
  }

  /// Add ONE wardrobe item end-to-end. Returns true if a piece was captured
  /// and sent to processing, false if the user backed out before capture.
  Future<bool> _addOneItem({int? pieceNumber}) async {
    final category = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bg,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('What are you adding?', style: AppType.h2),
            const SizedBox(height: 4),
            const Text('So we isolate exactly that piece.', style: TextStyle(color: AppColors.muted, fontSize: 13)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: [
                for (final (key, label) in const [('top', 'Top'), ('bottom', 'Bottom'), ('shoes', 'Shoes'), ('outerwear', 'Outerwear'), ('accessory', 'Accessory')])
                  GestureDetector(
                    onTap: () => Navigator.pop(context, key),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(AppRadius.control),
                        border: Border.all(color: AppColors.ink),
                      ),
                      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.ink)),
                    ),
                  ),
              ],
            ),
          ]),
        ),
      ),
    );
    if (category == null || !mounted) return false;

    // Smart-router hint: worn photos need Gemini extraction (rembg would cut
    // out the whole person); flat/hanger shots go to the free preprocessor.
    final isWorn = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.bg,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('How is it photographed?', style: AppType.h2),
            const SizedBox(height: 4),
            const Text('So we extract the piece the right way.', style: TextStyle(color: AppColors.muted, fontSize: 13)),
            const SizedBox(height: 16),
            Row(children: [
              for (final (worn, icon, label) in const [(true, Icons.accessibility_new, 'Worn on me'), (false, Icons.checkroom, 'Flat / hanger')])
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: worn ? 10 : 0),
                    child: GestureDetector(
                      onTap: () => Navigator.pop(context, worn),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(AppRadius.control),
                          border: Border.all(color: AppColors.ink),
                        ),
                        child: Column(children: [
                          Icon(icon, size: 24, color: AppColors.ink),
                          const SizedBox(height: 8),
                          Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: AppColors.ink)),
                        ]),
                      ),
                    ),
                  ),
                ),
            ]),
          ]),
        ),
      ),
    );
    if (isWorn == null || !mounted) return false;

    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppColors.bg,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined, color: AppColors.ink),
            title: const Text('Take a photo', style: TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined, color: AppColors.ink),
            title: const Text('Choose from gallery', style: TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (source == null) return false;
    // Hot path: native zero-lag capture; Flutter picker = fallback + gallery.
    Uint8List? bytes;
    if (source == ImageSource.camera) {
      bytes = await NativeLooktokEngine.instance.captureHighResPhoto();
    }
    if (bytes == null) {
      final file = await ImagePicker().pickImage(source: source, maxWidth: 800, maxHeight: 800, imageQuality: 80);
      if (file == null) return false;
      bytes = await file.readAsBytes();
    }
    if (!mounted) return false;
    // Centralized interceptor: garment must be readable BEFORE the 90s
    // upload+isolate pipeline (wardrobeItem rules: lenient size, garment
    // subject check).
    if (!await PhotoValidator.instance
        .validateAndProceed(context, bytes, ValidationFlowType.wardrobeItem)) {
      return false;
    }
    if (!mounted) return false;
    setState(() => _adding = true);
    // Premium overlay for the whole upload+isolate wait. Cancel pops it and
    // flips the flag — the in-flight request's result is then ignored (Dart
    // futures can't be killed; "abort" = discard the outcome safely).
    var cancelled = false;
    var dialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      useSafeArea: false, // full-bleed: the veil must cover the gesture zones too
      barrierColor: Colors.transparent, // the loader draws its own blur + veil
      builder: (dialogCtx) => PremiumWardrobeLoader(onCancel: () {
        cancelled = true;
        dialogOpen = false;
        Navigator.of(dialogCtx).pop();
      }),
    );
    try {
      // Hard timeout so the overlay/FAB can never wedge in a loading state.
      await ref
          .read(smartImageProcessingProvider)
          .processAndAnalyze(bytes,
              analysisType: SmartImageProcessingService.analysisWardrobe,
              category: category,
              isWorn: isWorn)
          .timeout(const Duration(seconds: 90));
      if (mounted && !cancelled) _reload();
    } catch (_) {
      if (mounted && !cancelled) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Could not add item')));
      }
    } finally {
      if (mounted && dialogOpen) Navigator.of(context).pop(); // close the overlay
      if (mounted) setState(() => _adding = false);
    }
    return true;
  }

  Future<void> _delete(WardrobeItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove this item?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(looktokApiProvider).deleteWardrobeItem(item.id, imagePath: item.imagePath);
    } catch (_) {}
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.read(cloudEnabledProvider)) {
      return Scaffold(
        appBar: AppBar(title: const Text('My Wardrobe', style: AppType.h2)),
        body: const Center(child: Padding(padding: EdgeInsets.all(40), child: Text('Wardrobe syncs in the cloud build.', textAlign: TextAlign.center, style: AppType.body))),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('My Wardrobe', style: AppType.h2)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _adding ? null : _add,
        backgroundColor: AppColors.ink,
        foregroundColor: Colors.white,
        icon: _adding
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.add_a_photo_outlined, color: AppColors.signature),
        label: Text(_adding ? 'Adding…' : 'Add item'),
      ),
      body: SafeArea(
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final all = (snap.data ?? const []).map(WardrobeItem.fromRow).toList();
            final items = _tab == 'all' ? all : all.where((w) => w.category == _tab).toList();
            if (all.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(40),
                  child: Column(mainAxisSize: MainAxisSize.min, children: const [
                    Icon(Icons.checkroom_outlined, size: 44, color: AppColors.muted),
                    SizedBox(height: 16),
                    Text('Your wardrobe is empty', style: AppType.h2),
                    SizedBox(height: 8),
                    Text('Add the clothes you own — we’ll build looks using only your pieces.',
                        textAlign: TextAlign.center, style: AppType.body),
                  ]),
                ),
              );
            }
            return Column(children: [
              // Horizontal category tabs — the digital closet's rails.
              SizedBox(
                height: 40,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: _tabs.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final (key, label) = _tabs[i];
                    final on = key == _tab;
                    return GestureDetector(
                      onTap: () => setState(() => _tab = key),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 15),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: on ? AppColors.ink : Colors.transparent,
                          borderRadius: BorderRadius.circular(AppRadius.control),
                          border: Border.all(color: on ? AppColors.ink : AppColors.line),
                        ),
                        child: Text(label,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: on ? Colors.white : AppColors.ink)),
                      ),
                    );
                  },
                ),
              ),
              Expanded(
                child: items.isEmpty
                    ? const Center(child: Text('Nothing in this category yet.', style: AppType.body))
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 96),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2, crossAxisSpacing: 14, mainAxisSpacing: 14, childAspectRatio: 0.78),
                        itemCount: items.length,
                        itemBuilder: (_, i) => _ItemCard(
                          item: items[i],
                          url: _url(items[i].imagePath),
                          onLongPress: () => _delete(items[i]),
                          onTap: () async {
                            final deleted = await Navigator.of(context).push<bool>(
                              MaterialPageRoute(builder: (_) => WardrobeItemDetailScreen(item: items[i])),
                            );
                            if (deleted == true && mounted) _reload();
                          },
                        ),
                      ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

class _ItemCard extends ConsumerWidget {
  const _ItemCard({required this.item, required this.url, required this.onLongPress, required this.onTap});
  final WardrobeItem item;
  final Future<String> url; // memoized by the parent — stable across rebuilds
  final VoidCallback onLongPress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            // Soft gray backing: product shots sit on it like a clean rail —
            // background-removed PNGs read as floating garments.
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: FutureBuilder<String>(
                  future: url,
                  builder: (_, s) => s.hasData
                      ? Padding(
                          padding: const EdgeInsets.all(10),
                          child: Image.network(s.data!, fit: BoxFit.contain, width: double.infinity,
                              errorBuilder: (_, _, _) => const SizedBox.shrink()),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(item.description.isEmpty ? 'Item' : item.description,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          Text(item.category.toUpperCase(),
              style: const TextStyle(color: AppColors.muted, fontSize: 9.5, fontWeight: FontWeight.w700, letterSpacing: 1)),
        ],
      ),
    );
  }
}

/// Sheet option card for the wardrobe add-mode chooser. `primary` = ink fill
/// (the recommended action), else white with a hairline border.
class _AddModeCard extends StatelessWidget {
  const _AddModeCard({
    required this.icon,
    required this.title,
    required this.caption,
    required this.primary,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String caption;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = primary ? Colors.white : AppColors.ink;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: primary ? AppColors.ink : Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: primary ? AppColors.ink : AppColors.line),
        ),
        child: Row(children: [
          Icon(icon, size: 22, color: primary ? AppColors.signature : AppColors.ink),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: fg)),
              if (caption.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(caption,
                    style: TextStyle(
                        fontSize: 12.5, height: 1.3,
                        color: primary ? Colors.white70 : AppColors.muted)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
