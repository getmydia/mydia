import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugPrint, debugPrintStack, kIsWeb, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/web_config.dart';
import '../player/device_profile.dart';
import '../cache/fetch_log.dart';

/// This device's decode-capability profile, probed once per app session and
/// held in memory for as long as the app runs.
///
/// A plain [DeviceProfileHolder], not a [FutureProvider]: the holder's
/// `profile` field is mutated in place once [detectDeviceProfile] resolves,
/// and mutating a field does not notify Riverpod, so nothing that reads this
/// provider ever rebuilds because the probe finished. That is deliberate.
/// `MydiaClient` (via `buildMydiaClient`) reads `profile` fresh on every
/// outgoing request instead, so:
///
/// - a request issued before the probe resolves carries no header, which
///   degrades to the server's no-profile behavior (correct, by design);
/// - a request issued after carries it, with no GraphQL client rebuild, no
///   orphaned in-flight query, and no subscriptions WebSocket reconnect.
///
/// The alternative this replaced, a watched `FutureProvider<DeviceProfile>`
/// feeding `graphqlClientProvider`, rebuilt the client the moment the probe
/// settled. Because the probe constructs and initializes a real native
/// player and is not fast, that meant the home screen's first queries on
/// every cold start went out with no header regardless, and then the client
/// was rebuilt out from under any request still in flight. Never persisted,
/// for the same staleness reason [DeviceProfile] itself gives: a stored
/// profile would survive an OS upgrade, a display swap, or a change in
/// hardware decode availability that the process holding it did not.
///
/// The no-header cold start above has a second-order effect worth spelling
/// out: the server's no-profile answer is `directPlaySupported: true` for
/// every file, and `selectFetchPolicy` (see `watch/query_watcher.dart`)
/// persists whatever a cold key's first fetch returns along with a fetch-log
/// entry, then serves that persisted answer via `cacheAndNetwork` on every
/// read within `kFreshnessThreshold`. Because the probe reliably loses that
/// race, the persisted answer is the uniform-`true` one, and it would keep
/// being served as current until the freshness window lapsed on its own,
/// long after the real profile was available. [applyDetectedProfile] closes
/// that gap by clearing the fetch log the moment the probe first resolves.
final deviceProfileHolderProvider = Provider<DeviceProfileHolder>((ref) {
  final holder = DeviceProfileHolder.instance;
  final fetchLog = ref.read(fetchLogProvider);
  // Not awaited: detectDeviceProfile never throws (every failure path
  // resolves to a fallback profile), and this provider's job is to hand back
  // the holder immediately, not to block on the probe. The eventual write is
  // a plain field mutation on an object nothing else observes reactively, so
  // there is no disposal race to guard against the way there is for a
  // Notifier's `state =`. applyDetectedProfile preserves that contract: its
  // own fetch-log clear is awaited inside this same continuation, never by
  // the provider body above.
  unawaited(detectDeviceProfile()
      .then((profile) => applyDetectedProfile(holder, profile, fetchLog)));
  return holder;
});

/// Writes [profile] into [holder] and, only the first time [holder] goes
/// from having no profile to having one, clears [fetchLog].
///
/// Whole-log clear rather than [FetchLog.clearFamily] targeted at the
/// specific queries that select `directPlaySupported` or
/// `streamingCandidates`: that would require enumerating those query names
/// here and keeping the list in sync as queries change, and a name missed on
/// either side of that sync would silently keep serving the stale
/// universal-`true` answer forever, which is the exact defect this function
/// exists to close. A whole-log clear cannot miss a query by name. The cost
/// is bounded and one-time: at most one extra `networkOnly` fetch per active
/// query key, paid once per app session, right when the probe resolves, not
/// on every read thereafter. The GraphQL response cache itself is never
/// touched, so any query with cached data it can still legitimately serve
/// keeps serving it; only the fetch log's staleness bookkeeping resets.
///
/// [wasUnset] is read before the write and is what makes this idempotent
/// without a separate "already cleared" flag: [DeviceProfileHolder.profile]
/// is documented as fixed for the rest of the session once set, so a second
/// call with the same holder finds it already non-null and does nothing.
///
/// A `clearAll()` failure is caught and logged rather than left to propagate:
/// this runs inside the same `.then` continuation `detectDeviceProfile` feeds
/// in [deviceProfileHolderProvider], and that function is documented as never
/// throwing for its callers. Letting a storage error escape here would break
/// that guarantee for a reason its callers have no reason to expect.
@visibleForTesting
Future<void> applyDetectedProfile(
  DeviceProfileHolder holder,
  DeviceProfile profile,
  FetchLog fetchLog,
) async {
  final wasUnset = holder.profile == null;
  holder.profile = profile;
  if (!wasUnset) return;

  try {
    await fetchLog.clearAll();
  } catch (error, stackTrace) {
    debugPrint(
        'Failed to clear fetch log after device profile resolved: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
}

/// True only when the player is served by a Mydia instance at `/player`.
///
/// That build talks to its own origin over plain HTTP. The public build at
/// web.mydia.dev is served by Cloudflare, has no instance behind it, and must
/// use the same p2p link the desktop app uses. The instance is the only thing
/// that injects `window.mydiaConfig`, so its presence is the signal.
bool get isInstanceHostedWeb => kIsWeb && getWebConfig() != null;
