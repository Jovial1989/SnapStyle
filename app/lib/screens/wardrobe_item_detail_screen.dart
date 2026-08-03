import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/wardrobe_item.dart';
import '../providers.dart';
import '../services/api_client.dart';
import '../services/looktok_api.dart';
import '../theme.dart';

/// Full-screen wardrobe item view: swipeable carousel (isolated garment → the
/// original photo it came from), pagination dots, name + category, delete with
/// confirmation. Pops `true` after a delete so the closet grid reloads.
class WardrobeItemDetailScreen extends ConsumerStatefulWidget {
  const WardrobeItemDetailScreen({super.key, required this.item});
  final WardrobeItem item;
  @override
  ConsumerState<WardrobeItemDetailScreen> createState() => _WardrobeItemDetailScreenState();
}

class _WardrobeItemDetailScreenState extends ConsumerState<WardrobeItemDetailScreen> {
  final _pager = PageController();
  final Map<String, Future<String>> _urls = {}; // stable per path — no refetch on page swipe
  int _page = 0;
  bool _deleting = false;
  bool _rendering = false;

  /// Photoreal try-on of THIS closet piece on the user's body photo.
  /// The render is persisted server-side; here we only show it.
  Future<void> _seeItOnMe(String category) async {
    setState(() => _rendering = true);
    try {
      final api = ref.read(looktokApiProvider);
      // Signed URL because the wardrobe bucket is private; the EF only accepts
      // our own storage host, so this is not an open-proxy hole.
      final garmentUrl = await api.wardrobeImageUrl(widget.item.imagePath);
      final r = await api.generateVton(
        garmentId: widget.item.id,
        category: category,
        garmentImageUrl: garmentUrl,
      );
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _VtonResultScreen(url: r.url, item: widget.item),
      ));
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Could not create the photoreal look — try again.')));
      }
    } finally {
      if (mounted) setState(() => _rendering = false);
    }
  }

  List<String> get _paths => [
        widget.item.imagePath,
        if (widget.item.originalImagePath != null) widget.item.originalImagePath!,
      ];

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove this item?'),
        content: const Text('It disappears from your closet and future looks.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: AppColors.flag, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      await ref.read(looktokApiProvider).deleteWardrobeItem(widget.item.id, imagePath: widget.item.imagePath);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() => _deleting = false);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Could not delete')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final paths = _paths;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text('Item'),
        actions: [
          IconButton(
            onPressed: _deleting ? null : _delete,
            icon: _deleting
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.ink))
                : const Icon(Icons.delete_outline, color: AppColors.ink),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: PageView.builder(
              controller: _pager,
              itemCount: paths.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (_, i) => Container(
                margin: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(AppRadius.card)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  child: FutureBuilder<String>(
                    future: _urls[paths[i]] ??= ref.read(looktokApiProvider).wardrobeImageUrl(paths[i]),
                    builder: (_, s) => s.hasData
                        ? Padding(
                            padding: const EdgeInsets.all(14),
                            child: Image.network(s.data!, fit: BoxFit.contain, width: double.infinity,
                                errorBuilder: (_, _, _) => const SizedBox.shrink()),
                          )
                        : const Center(
                            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.ink))),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Pagination dots (only when there's an original to swipe to).
          if (paths.length > 1)
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < paths.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _page ? 16 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _page ? AppColors.ink : AppColors.line,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
            ]),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(children: [
              Text(widget.item.description.isEmpty ? 'Item' : widget.item.description,
                  textAlign: TextAlign.center, style: AppType.h2),
              const SizedBox(height: 4),
              Text(widget.item.category.toUpperCase(),
                  style: const TextStyle(color: AppColors.muted, fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 2)),
              const SizedBox(height: 6),
              Text(_page == 0 ? 'THE PIECE' : 'AS SHOT',
                  style: const TextStyle(color: AppColors.muted, fontSize: 9.5, fontWeight: FontWeight.w600, letterSpacing: 1.6)),
            ]),
          ),
          // Photoreal try-on — only for garment types the engine can dress
          // (tops/bottoms/dresses); shoes & accessories never show the button.
          if (LooktokApi.vtonCategory(widget.item.category) case final cat?) ...[
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _rendering ? null : () => _seeItOnMe(cat),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.ink,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.pill)),
                  ),
                  child: _rendering
                      ? Row(mainAxisAlignment: MainAxisAlignment.center, children: const [
                          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                          SizedBox(width: 12),
                          Text('Dressing you…', style: TextStyle(fontWeight: FontWeight.w700)),
                        ])
                      : const Text('See it on me', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
        ]),
      ),
    );
  }
}

/// Full-bleed photoreal result. The image already lives at a permanent URL
/// (vton bucket) and in the look_generations ledger — nothing to save here.
class _VtonResultScreen extends StatelessWidget {
  const _VtonResultScreen({required this.url, required this.item});
  final String url;
  final WardrobeItem item;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(backgroundColor: Colors.white, title: const Text('On you')),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(AppRadius.card)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  width: double.infinity,
                  loadingBuilder: (_, child, p) => p == null
                      ? child
                      : const Center(
                          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.ink))),
                  errorBuilder: (_, _, _) =>
                      const Center(child: Text('Could not load the render', style: TextStyle(color: AppColors.muted))),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(item.description.isEmpty ? 'Photoreal try-on' : item.description,
                textAlign: TextAlign.center, style: AppType.h2),
          ),
          const SizedBox(height: 4),
          const Text('PHOTOREAL TRY-ON',
              style: TextStyle(color: AppColors.muted, fontSize: 9.5, fontWeight: FontWeight.w600, letterSpacing: 1.6)),
          const SizedBox(height: 18),
        ]),
      ),
    );
  }
}
