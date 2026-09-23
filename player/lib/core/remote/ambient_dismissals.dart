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
class AmbientDismissals extends Notifier<Set<AmbientDismissal>> {
  @override
  Set<AmbientDismissal> build() => const {};

  void dismiss(AmbientTarget target) =>
      state = {...state, AmbientDismissal.of(target)};
}

final ambientDismissalsProvider =
    NotifierProvider<AmbientDismissals, Set<AmbientDismissal>>(
  AmbientDismissals.new,
);
