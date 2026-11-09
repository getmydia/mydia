/// The playback session for a source. Lives here rather than on
/// `MediaSource`: sessions return presentation types, and `core/` does not
/// import presentation.
library;

import '../../../../core/p2p/media_proxy.dart';
import '../../../../core/player/device_profile.dart';
import '../../../../core/sources/files/cast/files_cast_bridge.dart';
import '../../../../core/sources/files/files_account.dart' show isSmbAccountId;
import '../../../../core/sources/files/files_media_source.dart';
import '../../../../core/sources/source.dart' show Source, SourceKind;
import '../../../../core/sources/jellyfin/jellyfin_media_source.dart';
import '../../../../core/sources/media_source.dart';
import '../../../../core/sources/mydia/mydia_source.dart';
import '../../../../core/sources/plex/plex_media_source.dart';
import '../../../../core/sources/stash/stash_media_source.dart';
import '../../../../domain/sources/item.dart';
import 'files_playback_session.dart';
import 'jellyfin_playback_session.dart';
import 'mydia_playback_session.dart';
import 'playback_session.dart';
import 'source_playback_session.dart';
import 'plex_playback_session.dart';
import 'stash_playback_session.dart';

/// Null for a source this app cannot play from. [showId] and
/// [seasonNumber] only matter to Mydia, whose episode navigation needs them.
PlaybackSession? playbackSessionFor(
  MediaSource source,
  ItemRef item,
  String fileId, {
  required MediaProxy Function() proxy,
  String? showId,
  int? seasonNumber,
  FilesCastBridge Function()? bridge,
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
      FilesMediaSource() => FilesPlaybackSession(
          source: source,
          item: item,
          fileId: fileId,
          bridge: bridge?.call(),
        ),
      MydiaSource() => MydiaPlaybackSession(
          source: source,
          item: item,
          fileId: fileId,
          showId: showId,
          seasonNumber: seasonNumber,
          proxy: proxy,
        ),
      _ => null,
    };

/// Whether [source] is a files source backed by an SMB share, the only kind
/// whose URLs ride the SMB loopback listener.
bool isSmbSource(Source source) =>
    source.kind == SourceKind.files && isSmbAccountId(source.account.id);

/// Whether [session] plays from an SMB share, so a move of the SMB
/// listener's port invalidates its URL.
bool playsFromSmb(PlaybackSession session) =>
    session is SourcePlaybackSession && isSmbSource(session.source.source);
