import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Anchor Items (partial try-on): which body zones are LOCKED (anchors the AI
/// must not touch) and which are GENERATING right now. The Look Editor is the
/// writer; anything else (payload builders, badges, future screens) observes.
class OutfitState {
  const OutfitState({this.lockedZones = const {}, this.generatingZones = const {}});
  final Set<String> lockedZones; // slot names: top / bottom / shoes / …
  final Set<String> generatingZones;

  OutfitState copyWith({Set<String>? lockedZones, Set<String>? generatingZones}) =>
      OutfitState(
        lockedZones: lockedZones ?? this.lockedZones,
        generatingZones: generatingZones ?? this.generatingZones,
      );

  /// The explicit contract line for render payloads: which zones are anchors.
  /// Empty string when nothing is locked.
  String get lockedPayloadClause => lockedZones.isEmpty
      ? ''
      : 'LOCKED ANCHOR ZONES (reproduce pixel-faithful, do NOT alter): '
          '${lockedZones.join(', ')}. ';
}

class OutfitStateNotifier extends Notifier<OutfitState> {
  @override
  OutfitState build() => const OutfitState();

  void setLocked(Set<String> zones) =>
      state = state.copyWith(lockedZones: {...zones});

  void setGenerating(String zone, bool generating) {
    final g = {...state.generatingZones};
    generating ? g.add(zone) : g.remove(zone);
    state = state.copyWith(generatingZones: g);
  }

  void reset() => state = const OutfitState();
}

final outfitStateProvider =
    NotifierProvider<OutfitStateNotifier, OutfitState>(OutfitStateNotifier.new);
