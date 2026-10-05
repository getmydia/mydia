/// The playback session for a third-party source. Lives here rather than
/// on `MediaSource`: sessions return presentation types, and `core/` does
/// not import presentation.
library;

import '../../../../core/p2p/local_proxy_service.dart';
import '../../../../core/player/device_profile.dart';
import '../../../../core/sources/jellyfin/jellyfin_media_source.dart';
import '../../../../core/sources/media_source.dart';
import '../../../../core/sources/mydia/mydia_guest_source.dart';
import '../../../../core/sources/plex/plex_media_source.dart';
import '../../../../core/sources/stash/stash_media_source.dart';
import '../../../../domain/sources/item.dart';
import 'jellyfin_playback_session.dart';
import 'mydia_guest_playback_session.dart';
import 'playback_session.dart';
import 'plex_playback_session.dart';
import 'stash_playback_session.dart';

/// Null for a source this app cannot play from, which includes a guest
/// Mydia when [proxy] is not given.
PlaybackSession? playbackSessionFor(
  MediaSource source,
  ItemRef item,
  String fileId, {
  LocalProxyService Function()? proxy,
}) =>
    switch (source) {
      PlexMediaSource() => PlexPlaybackSession(
          source: source,
          item: item,
          fileId: fileId,
          profile: DeviceProfileHolder.instance.profile,
        ),
      StashMediaSource() =>
        StashPlaybackSession(source: source, item: item, fileId: fileId),
      JellyfinMediaSource() => JellyfinPlaybackSession(
          source: source,
          item: item,
          fileId: fileId,
          profile: DeviceProfileHolder.instance.profile,
        ),
      MydiaGuestSource() when proxy != null => MydiaGuestPlaybackSession(
          source: source,
          item: item,
          fileId: fileId,
          proxy: proxy,
        ),
      _ => null,
    };
