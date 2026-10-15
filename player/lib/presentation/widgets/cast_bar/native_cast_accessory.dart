import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cast/cast_providers.dart';
import '../../../core/platform/native_tab_bar_channel.dart';
import '../../../core/router/navigator_keys.dart';
import '../../../domain/models/cast_device.dart';
import '../cast_controls_sheet.dart';
import 'cast_bar_state.dart';

/// The native accessory for [state], or null for none. One row per state the
/// Flutter bar can show, in the bar's own words.
///
/// Play/pause appears only while playing and not syncing, which is when the
/// Flutter bar's play/pause button is enabled. Every other action
/// (reconnect, stop, dismiss) is in the sheet a tap opens.
NativeAccessory? nativeAccessoryFor(CastBarState? state) => switch (state) {
      null => null,
      CastBarAmbient(:final target, :final deviceName) => NativeAccessory(
          title: target.snapshot.title,
          subtitle: CastBarText.ambientStatus(deviceName),
          artwork: target.snapshot.imageUrl,
          symbol: 'tv',
        ),
      CastBarOffline(:final device) => NativeAccessory(
          title: device.name,
          subtitle: CastBarText.offlineStatus,
          symbol: 'airplayvideo',
        ),
      CastBarConnecting(:final device) => NativeAccessory(
          title: CastBarText.connectingTitle(device.name),
          symbol: 'airplayvideo',
        ),
      CastBarStale(:final session) => NativeAccessory(
          title: session.mediaInfo?.title ?? session.device.name,
          subtitle: CastBarText.staleStatus(session.device.name),
          artwork: session.mediaInfo?.imageUrl,
          symbol: 'airplayvideo',
        ),
      CastBarIdle(:final device) => NativeAccessory(
          title: CastBarText.idleTitle(device.name),
          subtitle: CastBarText.idleStatus,
          symbol: 'airplayvideo.circle.fill',
        ),
      CastBarPlaying(:final session) => NativeAccessory(
          title: session.mediaInfo?.title ?? session.device.name,
          subtitle: CastBarText.playingStatus(
            session.device.name,
            syncing: session.isSyncing,
          ),
          artwork: session.mediaInfo?.imageUrl,
          symbol: 'airplayvideo',
          playing: session.isSyncing
              ? null
              : session.playbackState == CastPlaybackState.playing,
        ),
    };

/// Mirrors the cast bar into the native tab bar's accessory, and answers its
/// taps. Draws nothing itself. Mounted by `AppShell` on the native path.
class NativeCastAccessory extends ConsumerStatefulWidget {
  const NativeCastAccessory({super.key});

  @override
  ConsumerState<NativeCastAccessory> createState() =>
      _NativeCastAccessoryState();
}

class _NativeCastAccessoryState extends ConsumerState<NativeCastAccessory> {
  late final NativeTabBarChannel _channel =
      ref.read(nativeTabBarChannelProvider);
  StreamSubscription<NativeTabBarEvent>? _events;

  /// The native accessory sits above Flutter's modal barrier, so it can be
  /// tapped again while the sheet is up.
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    _events = _channel.events.listen(_onEvent);
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    unawaited(_channel.setAccessory(null));
    super.dispose();
  }

  void _onEvent(NativeTabBarEvent event) {
    switch (event) {
      case NativeAccessoryTapped():
        if (!mounted || _sheetOpen) return;
        _sheetOpen = true;
        // The router's root navigator, so the sheet covers the shell; the
        // fallback is for widget tests, which have no router.
        try {
          unawaited(
            showCastControlsSheet(
              rootNavigatorKey.currentContext ?? context,
            ).whenComplete(() {
              if (mounted) _sheetOpen = false;
            }),
          );
        } catch (e) {
          // A synchronous throw (no navigator) never reaches whenComplete,
          // which would leave every later tap ignored.
          _sheetOpen = false;
          debugPrint('[NativeCastAccessory] cast sheet failed to open: $e');
        }
      case NativeAccessoryPlayPause():
        unawaited(_togglePlayback());
      case NativeTabSelected() || NativeInsetsChanged():
        break;
    }
  }

  Future<void> _togglePlayback() async {
    final state = ref.read(castBarStateProvider);
    if (state is! CastBarPlaying) return;
    try {
      final manager = await ref.read(castSessionManagerProvider.future);
      await toggleCastPlayback(manager, state.session);
    } catch (e) {
      debugPrint('[NativeCastAccessory] play/pause failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final accessory = nativeAccessoryFor(ref.watch(castBarStateProvider));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_channel.setAccessory(accessory));
    });
    return const SizedBox.shrink();
  }
}
