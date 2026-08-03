import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import '../models/analysis.dart';
import '../providers.dart';
import '../theme.dart';
import 'look_editor_screen.dart';

/// History tab: the user's past outfit reviews + generated looks (retention loop).
/// Cloud-only — reads succeeded `generations`. Empty/placeholder otherwise.
class WardrobeScreen extends ConsumerStatefulWidget {
  const WardrobeScreen({super.key});
  @override
  ConsumerState<WardrobeScreen> createState() => _WardrobeScreenState();
}

class _WardrobeScreenState extends ConsumerState<WardrobeScreen> {
  Future<List<Map<String, dynamic>>>? _future;
  static const _filters = ['All', 'Date', 'Office', 'Active', 'Casual'];
  String _filter = 'All';

  @override
  void initState() {
    super.initState();
    if (ref.read(cloudEnabledProvider)) _future = ref.read(looktokApiProvider).history();
  }

  void _reload() => setState(() => _future = ref.read(looktokApiProvider).history());

  List<String> _paths(Map<String, dynamic> item) {
    final output = ((item['output'] ?? {}) as Map).cast<String, dynamic>();
    final many = output['image_paths'];
    if (many is List && many.isNotEmpty) return many.map((e) => e.toString()).toList();
    final one = output['image_path']?.toString();
    return (one == null || one.isEmpty) ? const [] : [one];
  }

  Future<bool> _delete(Map<String, dynamic> item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(item['type'] == 'critique' ? 'Remove this review?' : 'Remove this look?'),
        content: const Text('It will be deleted from My Looks.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return false;
    try {
      await ref.read(looktokApiProvider).deleteLook(item['id'].toString(), imagePaths: _paths(item));
    } catch (_) {}
    if (mounted) _reload();
    return true;
  }

  Future<void> _open(Map<String, dynamic> item) async {
    final api = ref.read(looktokApiProvider);
    final output = ((item['output'] ?? {}) as Map).cast<String, dynamic>();
    final path = (output['image_path'] ?? '').toString();
    if (path.isEmpty) return;

    if (item['type'] == 'critique') {
      showDialog(context: context, barrierDismissible: false, builder: (_) => const _Loader());
      try {
        final bytes = await api.generationBytes(path);
        final result = AnalysisResult.fromResponse(output);
        if (!mounted) return;
        Navigator.of(context).pop(); // dismiss loader
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => LookEditorScreen(imageBytes: bytes, analysis: result, score: result.overallScore)));
      } catch (_) {
        if (mounted) Navigator.of(context).pop();
      }
    } else {
      // Download bytes first (behind a loader) so the viewer opens straight onto
      // the photo — no black flash while a network image loads.
      showDialog(context: context, barrierDismissible: false, builder: (_) => const _Loader());
      try {
        final bytes = await api.generationBytes(path);
        if (!mounted) return;
        Navigator.of(context).pop(); // dismiss loader
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => _LookViewer(
                  bytes: bytes,
                  onDelete: () => _delete(item),
                )));
      } catch (_) {
        if (mounted) Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Looks', style: AppType.h2),
        actions: [
          if (_future != null)
            IconButton(icon: const Icon(Icons.refresh), onPressed: _reload, tooltip: 'Refresh'),
        ],
      ),
      body: SafeArea(
        child: _future == null
            ? const _Empty(cloud: false)
            : FutureBuilder<List<Map<String, dynamic>>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final all = snap.data ?? const [];
                  if (all.isEmpty) return const _Empty(cloud: true);
                  // Occasion filter (chips): match against input.occasion.
                  final items = _filter == 'All'
                      ? all
                      : all.where((e) {
                          final o = (((e['input'] ?? {}) as Map)['occasion'] ?? '').toString().toLowerCase();
                          return o.contains(_filter.toLowerCase());
                        }).toList();
                  // Segment the grid: Fit Reviews vs Styled Looks (P1).
                  final reviews = items.where((e) => e['type'] == 'critique').toList();
                  final looks = items.where((e) => e['type'] != 'critique').toList();
                  Widget grid(List<Map<String, dynamic>> xs) => GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2, crossAxisSpacing: 14, mainAxisSpacing: 14, childAspectRatio: 0.72),
                        itemCount: xs.length,
                        itemBuilder: (_, i) => _Card(
                            item: xs[i],
                            onTap: () => _open(xs[i]),
                            onLongPress: () => _delete(xs[i]),
                            onDelete: () => _delete(xs[i])),
                      );
                  Widget header(String t) => Padding(
                        padding: const EdgeInsets.only(bottom: 12, top: 4),
                        child: Text(t,
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.6, color: AppColors.muted)),
                      );
                  return RefreshIndicator(
                    onRefresh: () async => _reload(),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      children: [
                        // Occasion filter chips — thin outline off, solid black on.
                        SizedBox(
                          height: 38,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _filters.length,
                            separatorBuilder: (_, _) => const SizedBox(width: 8),
                            itemBuilder: (_, i) {
                              final f = _filters[i];
                              final on = f == _filter;
                              return GestureDetector(
                                onTap: () => setState(() => _filter = f),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: on ? AppColors.ink : Colors.transparent,
                                    borderRadius: BorderRadius.circular(AppRadius.control),
                                    border: Border.all(color: AppColors.ink, width: 1),
                                  ),
                                  child: Text(f,
                                      style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: on ? Colors.white : AppColors.ink)),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (looks.isEmpty && reviews.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('Nothing here for this occasion yet.', style: AppType.body),
                          ),
                        if (looks.isNotEmpty) ...[header('STYLED LOOKS'), grid(looks), const SizedBox(height: 20)],
                        if (looks.isEmpty && reviews.isNotEmpty)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 20),
                            child: Text('No styled looks yet — try “What should I wear?”', style: AppType.body),
                          ),
                        if (reviews.isNotEmpty) ...[header('FIT REVIEWS'), grid(reviews)],
                        if (reviews.isEmpty && looks.isNotEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 0),
                            child: Text('No fit reviews yet — snap your outfit for an honest read.', style: AppType.body),
                          ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _Card extends ConsumerWidget {
  const _Card({required this.item, required this.onTap, this.onLongPress, this.onDelete});
  final Map<String, dynamic> item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDelete;

  static String _relDate(String? iso) {
    final d = DateTime.tryParse(iso ?? '');
    if (d == null) return '';
    final diff = DateTime.now().toUtc().difference(d.toUtc());
    if (diff.inHours < 1) return 'just now';
    if (diff.inHours < 24) return 'today';
    if (diff.inDays == 1) return 'yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${(diff.inDays / 7).floor()}w ago';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final output = ((item['output'] ?? {}) as Map).cast<String, dynamic>();
    final path = (output['image_path'] ?? '').toString();
    final isCritique = item['type'] == 'critique';
    // Every review card shows a score or an explicit no-score state (P0-3).
    final score = isCritique
        ? ((((output['analysis'] ?? {}) as Map)['overall']?['score'])?.toString() ?? '—')
        : null;
    final input = ((item['input'] ?? {}) as Map);
    final occasion = input['occasion']?.toString();
    final subject = input['subject']?.toString(); // guest name (§14.10)
    final when = _relDate(item['created_at']?.toString());
    final title = isCritique
        ? (subject != null ? "$subject's review" : 'Fit review')
        : (subject != null
            ? "$subject's look"
            : (occasion != null && occasion != 'Edited' ? '$occasion look' : 'Look'));

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: AppColors.surface),
            // Uniform framing: cover + TOP-CENTER anchor so every card shows
            // the head/shoulders at the same place regardless of whether the
            // source render is full-body or a closer crop — no more "some near,
            // some far".
            FutureBuilder<String>(
              future: ref.read(looktokApiProvider).lookImageUrl(path),
              builder: (_, s) => s.hasData
                  ? Image.network(s.data!,
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                      errorBuilder: (_, _, _) => const SizedBox())
                  : const SizedBox(),
            ),
            Align(
              alignment: Alignment.bottomLeft,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 24, 12, 12),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xB3000000)]),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                    if (when.isNotEmpty)
                      Text(when, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  ],
                ),
              ),
            ),
            // Visible delete — long-press worked but nobody discovers it.
            if (onDelete != null)
              Positioned(
                top: 8,
                left: 8,
                child: GestureDetector(
                  onTap: onDelete,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 28, height: 28,
                    decoration: const BoxDecoration(color: Color(0x8C000000), shape: BoxShape.circle),
                    child: const Icon(Icons.delete_outline, size: 15, color: Colors.white),
                  ),
                ),
              ),
            if (score != null)
              Positioned(
                top: 10,
                right: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(999)),
                  child: Text(score == '—' ? 'no score' : '$score/10',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.cloud});
  final bool cloud;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.grid_view_outlined, size: 40, color: AppColors.muted),
            const SizedBox(height: 16),
            const Text('No looks yet', style: AppType.h2),
            const SizedBox(height: 8),
            Text(
              cloud
                  ? 'Your outfit reviews and generated looks will collect here.'
                  : 'History syncs in the cloud build.',
              textAlign: TextAlign.center,
              style: AppType.body,
            ),
          ],
        ),
      ),
    );
  }
}

class _Loader extends StatelessWidget {
  const _Loader();
  @override
  Widget build(BuildContext context) => const Center(child: CircularProgressIndicator());
}

/// Full-screen look viewer: opens straight onto the image (bytes preloaded, no
/// black flash), with Save-to-Photos + Share + Delete actions.
class _LookViewer extends StatefulWidget {
  const _LookViewer({required this.bytes, this.onDelete});
  final Uint8List bytes;

  /// Deletes the underlying generation (with its own confirm dialog); returns
  /// true only when the user confirmed — the viewer pops itself then.
  final Future<bool> Function()? onDelete;
  @override
  State<_LookViewer> createState() => _LookViewerState();
}

class _LookViewerState extends State<_LookViewer> {
  bool _busy = false;

  void _snack(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await Gal.putImageBytes(widget.bytes, name: 'looktok_${DateTime.now().millisecondsSinceEpoch}');
      if (mounted) _snack('Saved to Photos');
    } catch (_) {
      if (mounted) _snack('Couldn’t save — allow photo access in Settings');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final f = File('${Directory.systemTemp.path}/looktok_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await f.writeAsBytes(widget.bytes);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(f.path)], text: 'My look, styled with Looktok'),
      );
    } catch (_) {
      if (mounted) _snack('Couldn’t open share');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Editorial studio, not a black void: soft ivory radial backdrop + a floor
    // shadow, with the look mounted in a white rounded "frame" card.
    return Scaffold(
      backgroundColor: const Color(0xFFF1F0EB),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.ink,
        elevation: 0,
        actions: [
          IconButton(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Save to Photos',
          ),
          IconButton(
            onPressed: _busy ? null : _share,
            icon: const Icon(Icons.ios_share),
            tooltip: 'Share',
          ),
          if (widget.onDelete != null)
            IconButton(
              onPressed: _busy
                  ? null
                  : () async {
                      final nav = Navigator.of(context); // capture pre-await
                      final deleted = await widget.onDelete!();
                      if (deleted && mounted) nav.maybePop();
                    },
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
            ),
        ],
      ),
      body: Stack(fit: StackFit.expand, children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.25), radius: 1.25,
              colors: [Color(0xFFF9F8F5), Color(0xFFF1F0EB), Color(0xFFE7E5DE)],
              stops: [0.0, 0.55, 1.0],
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
            child: Center(
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: const Color(0xFFE6E3DC)),
                  boxShadow: const [
                    BoxShadow(color: Color(0x1F000000), blurRadius: 40, offset: Offset(0, 20)),
                  ],
                ),
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: Image.memory(widget.bytes, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
