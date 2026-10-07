import '../../domain/models/media_file.dart';
import '../../domain/sources/item.dart';
import 'media_file_selector.dart';

/// Picks the file to play from [files], given the current [screenWidth].
///
/// Extracted from SmartPlayButton so the show detail hero and the home rails
/// cannot disagree about which file a given item plays. Stays async because
/// [DeviceContext.detect] probes the network type.
///
/// A single-element list short-circuits: there is nothing to choose between,
/// and probing the network to confirm that would be wasted latency on the
/// most common path.
Future<MediaFile?> pickBestFile(
  List<MediaFile> files,
  double screenWidth,
) async {
  if (files.isEmpty) return null;
  if (files.length == 1) return files.first;

  final context = await DeviceContext.detect(screenWidth);
  return MediaFileSelector.selectBest(files, context);
}

/// [pickBestFile] over a source item's versions, as the id the player takes.
///
/// Every play path that starts from a source item goes through this, so a
/// remote play, a Continue Watching tap and a calendar tap pick the same
/// version a local Play button would.
Future<String?> pickBestVersionId(
  List<MediaVersion> versions,
  double screenWidth,
) async =>
    (await pickBestFile(filesFromVersions(versions), screenWidth))?.id;
