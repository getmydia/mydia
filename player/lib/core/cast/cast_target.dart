import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/cast_device.dart';

/// The device the user has chosen to cast to.
///
/// Distinct from the session (`castSessionProvider`/`CastSessionManager`),
/// which is what is actually connected right now. Selecting a device opens a
/// real, media-less connection immediately (`CastSessionManager.connectTo`)
/// and that connection is what the session describes — but the target
/// outlives it: it persists across a lost or dropped connection, and
/// `PlayerScreen` still reads it to decide where the next playback should
/// open. So a target with no live session behind it is a normal, expected
/// state (a failed connect, an idle-timed-out receiver), not an error —
/// `CastMiniController`'s offline row and `CastConnection.chosenOffline`
/// exist specifically to name it.
class CastTargetNotifier extends Notifier<CastDevice?> {
  @override
  CastDevice? build() => null;

  void set(CastDevice device) => state = device;

  void clear() => state = null;
}

final castTargetProvider =
    NotifierProvider<CastTargetNotifier, CastDevice?>(CastTargetNotifier.new);
