/// Downloads for servers that hand out their files as-is (Plex, Jellyfin,
/// Stash): one option, the original, fetched with the source's credentials.
library;

import 'package:collection/collection.dart';

import '../../domain/models/download_option.dart';
import '../../domain/models/download_plan.dart';
import '../../domain/sources/item.dart';
import '../../domain/sources/source_error.dart';
import 'media_source.dart';

const originalOptionId = 'original';

/// The version a download takes: the item's default, else its first.
MediaVersion? downloadVersion(ItemDetail detail) {
  final id = detail.summary.defaultVersionId;
  return detail.versions.firstWhereOrNull((v) => v.id == id) ??
      detail.versions.firstOrNull;
}

/// Bitrate times duration. Servers rarely send a file size in item detail.
int? estimatedBytes(MediaVersion version) {
  final kbps = version.bitrateKbps;
  final seconds = version.durationSeconds;
  if (kbps == null || seconds == null) return null;
  return kbps * 1000 ~/ 8 * seconds;
}

DownloadOption originalOption(MediaVersion version) => DownloadOption(
      resolution: originalOptionId,
      label: 'Original',
      estimatedSize: estimatedBytes(version) ?? 0,
      container: version.container,
    );

Future<List<DownloadOption>> originalOptions(
    MediaSource source, ItemRef ref) async {
  final version = downloadVersion(await source.item(ref));
  return version == null ? const [] : [originalOption(version)];
}

Future<DirectFile> originalFile(
  MediaSource source,
  ItemRef ref, {
  required Future<Uri> Function(MediaVersion version) url,
  required Future<Map<String, String>> Function() headers,
}) async {
  final version = downloadVersion(await source.item(ref)) ??
      (throw const SourceException.unsupported(
          'This server offers no file to download for this item.'));
  return DirectFile(
    url: (await url(version)).toString(),
    headers: await headers(),
    extension: extensionForContainer(version.container),
    expectedBytes: estimatedBytes(version),
  );
}
