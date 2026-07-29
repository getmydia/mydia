import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/cast_device.dart';

/// The device the user has chosen to cast to, before anything is playing.
///
/// Deliberately *not* a connection. Setting a target contacts nothing and
/// launches no receiver app — it only records an intent, which `PlayerScreen`
/// reads when playback starts so the media opens on the receiver instead of
/// locally. Modelling it this way keeps `CastSessionManager` owning exactly
/// one concept (an active session with media) rather than growing a
/// media-less idle state that the session store, LAN gating and the progress
/// pump would all have to learn.
class CastTargetNotifier extends Notifier<CastDevice?> {
  @override
  CastDevice? build() => null;

  void set(CastDevice device) => state = device;

  void clear() => state = null;
}

final castTargetProvider =
    NotifierProvider<CastTargetNotifier, CastDevice?>(CastTargetNotifier.new);
