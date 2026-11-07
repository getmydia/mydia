import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ambient_targets.dart';

/// One "Playing on X" banner the user closed: that player, that title.
///
/// Keyed on the title as well as the node so the banner returns when the
/// same player moves on to something else, which is new information.
@immutable
class AmbientDismissal {
  const AmbientDismissal(this.nodeId, this.title);

  factory AmbientDismissal.of(AmbientTarget target) =>
      AmbientDismissal(target.device.id.toLowerCase(), target.snapshot.title);

  final String nodeId;
  final String title;

  @override
  bool operator ==(Object other) =>
      other is AmbientDismissal &&
      other.nodeId == nodeId &&
      other.title == title;

  @override
  int get hashCode => Object.hash(nodeId, title);
}

/// Banners closed this app session. In memory on purpose: a restart is a
/// fresh look at what is playing.
///
/// A dismissal lasts one viewing. [forgetNode] drops it once that player is
/// seen stopped, so the next time it plays, even the same title, the banner
/// is back. [clear] is the manual way back: opening the cast picker.
class AmbientDismissals extends Notifier<Set<AmbientDismissal>> {
  @override
  Set<AmbientDismissal> build() => const {};

  void dismiss(AmbientTarget target) => dismissKey(AmbientDismissal.of(target));

  /// For callers holding a cast session rather than an [AmbientTarget].
  /// [key]'s node id must already be lower-cased, as [AmbientDismissal.of]
  /// does.
  void dismissKey(AmbientDismissal key) => state = {...state, key};

  /// Drops every dismissal for [nodeId], which was found not playing.
  /// Leaves state untouched when none match: the probe reports every idle
  /// device on every sweep, and most were never dismissed.
  void forgetNode(String nodeId) {
    final id = nodeId.toLowerCase();
    if (!state.any((d) => d.nodeId == id)) return;
    state = {
      for (final d in state)
        if (d.nodeId != id) d,
    };
  }

  void clear() {
    if (state.isNotEmpty) state = const {};
  }
}

final ambientDismissalsProvider =
    NotifierProvider<AmbientDismissals, Set<AmbientDismissal>>(
  AmbientDismissals.new,
);
