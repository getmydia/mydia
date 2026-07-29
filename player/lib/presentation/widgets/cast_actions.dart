import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cast/cast_backend.dart';
import '../../core/cast/cast_providers.dart';
import '../../core/cast/cast_session_manager.dart';
import '../../core/cast/cast_target.dart';
import '../../core/p2p/local_proxy_service.dart';
import 'cast_button.dart';
import 'cast_device_picker.dart';

/// Turn a cast failure into something the user can act on.
///
/// Was private to `PlayerScreen`. It now has multiple callers — the player
/// screen's device picker, the player screen's failed-target fallback, and
/// every other cast affordance's [pickCastDevice] — so it lives here.
///
/// A bare "cast failed" leaves a firewall or codec problem undiagnosable, so
/// the unreachable case names the actual port that needs to be open. That
/// port comes from [LocalProxyService], which requires a [WidgetRef] to
/// look up — callers that have one (anything running inside a widget tree)
/// should pass it; callers that don't (like this file's own tests) get the
/// same message minus the port hint, matching what the original method did
/// whenever the proxy wasn't LAN-accessible.
String castErrorMessage(CastBackendException e, {WidgetRef? ref}) {
  final proxy = ref?.read(localProxyServiceProvider);

  switch (e.kind) {
    case CastFailureKind.unreachable:
      final port = proxy != null && proxy.isLanAccessible ? proxy.port : null;
      final portHint =
          port == null ? '' : ' Allow incoming connections on port $port.';
      return 'The device could not reach your media. Check that both are on '
          'the same network and that your firewall is not blocking '
          'Mydia.$portHint';
    case CastFailureKind.mediaLoadFailed:
      return 'The device could not play this file. It may not support the '
          'video or audio format.';
    case CastFailureKind.connectionLost:
      return 'Lost the connection to the device.';
    case CastFailureKind.discoveryDenied:
      return 'Mydia needs local network permission to find cast devices.';
    case CastFailureKind.unknown:
      return 'Casting failed: ${e.message}';
  }
}

/// The shared "user tapped a cast affordance" entry point, for every screen
/// except the player.
///
/// Branches on what is playing rather than on which screen called it:
/// re-target a live session, or record an intent for the next playback.
/// `PlayerScreen` keeps its own picker because it holds the loaded media and
/// can therefore cast immediately.
Future<void> pickCastDevice(BuildContext context, WidgetRef ref) async {
  final device = await showCastDevicePicker(context);
  if (device == null || !context.mounted) return;

  final session = ref.read(castSessionProvider).value;

  // Nothing playing: record the intent and stop. Connecting here would launch
  // a receiver app with no media to show.
  if (session == null) {
    ref.read(castTargetProvider.notifier).set(device);
    return;
  }

  // Already on that receiver — picking it again should do nothing rather than
  // tear down and rebuild the session the user is watching.
  if (session.device.id == device.id) return;

  final persisted =
      ref.read(castSessionManagerProvider).value?.persistedSession;
  if (persisted == null) {
    // A live session with nothing persisted behind it cannot be moved; fall
    // back to recording the intent so the next play lands on the new device.
    ref.read(castTargetProvider.notifier).set(device);
    return;
  }

  try {
    final manager = await ref.read(castSessionManagerProvider.future);
    await manager.startCast(
      device: device,
      request: CastLaunchRequest(
        fileId: persisted.fileId,
        mediaId: persisted.mediaId,
        mediaType: persisted.mediaType,
        title: persisted.title,
        startPosition: persisted.position,
        duration: persisted.duration,
      ),
    );
  } on CastBackendException catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(castErrorMessage(e, ref: ref)),
      backgroundColor: Colors.red,
    ));
  } catch (e) {
    // Anything that isn't a CastBackendException: the session manager
    // itself resolving (Hive, GraphQL client), or a non-typed failure from
    // _setLanAccess/_store.save inside startCast. Without this, those
    // failures would close the picker with no snackbar and no log.
    debugPrint('[cast_actions] Unexpected error starting cast: $e');
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Failed to start casting: $e'),
      backgroundColor: Colors.red,
    ));
  }
}

/// The cast affordance for screens with no app bar to put it in.
///
/// `AppShell` has no app bar of its own, and on desktop the browse screens
/// deliberately suppress theirs (`HomeScreen` passes `appBar: null`;
/// `UnwatchedScreen` and friends return a zero-height `SizedBox.shrink()`).
/// An app-bar-only affordance would therefore be invisible on macOS across
/// most of the app, so the shell pins this into its existing `Stack`.
class CastOverlayButton extends ConsumerWidget {
  /// Distance from the top of the safe area.
  ///
  /// Mobile browse screens *do* render an app bar with its own actions, so
  /// this clears it rather than sitting on top of it.
  final double topInset;

  const CastOverlayButton({super.key, required this.topInset});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Positioned(
      top: topInset,
      right: 12,
      child: SafeArea(
        child: CastButton(onPressed: () => pickCastDevice(context, ref)),
      ),
    );
  }
}
