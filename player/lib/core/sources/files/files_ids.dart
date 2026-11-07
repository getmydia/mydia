import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The `externalId` scheme of a files library, in one place.
///
/// A matched item uses the TMDB id as its base (`603`), a group the relay has
/// not answered for yet uses a provisional base (`p<sha16(groupKey)>`).
///
/// | Item | id |
/// | --- | --- |
/// | movie, show | `<base>` |
/// | season | `<base>-<n>` |
/// | episode | `<base>-<s>-<e>` |
/// | unmatched file | `f<fileKey>` |

/// `p` + first 16 hex chars of SHA-256 over [groupKey].
String provisionalKey(String groupKey) =>
    'p${sha256.convert(utf8.encode(groupKey)).toString().substring(0, 16)}';

/// The base of a matched item.
String tmdbBase(int tmdbId) => '$tmdbId';

String movieId(String base) => base;
String showId(String base) => base;
String seasonId(String base, int season) => '$base-$season';
String episodeId(String base, int season, int episode) =>
    '$base-$season-$episode';

/// The id of a file that belongs to no matched group.
String unmatchedFileId(String fileKey) => 'f$fileKey';

/// An id taken apart.
class FilesId {
  const FilesId({
    required this.base,
    this.season,
    this.episode,
    this.fileKey,
  });

  /// TMDB id as text, or a provisional key. Null for an unmatched file.
  final String? base;
  final int? season;
  final int? episode;

  /// Set for an unmatched file.
  final String? fileKey;

  bool get isUnmatchedFile => fileKey != null;
  bool get isProvisional => base != null && base!.startsWith('p');

  /// The TMDB id, when this id is matched.
  int? get tmdbId => base == null || isProvisional ? null : int.tryParse(base!);
}

/// Null when [id] is not in the scheme.
FilesId? parseFilesId(String id) {
  if (id.length > 1 && id.startsWith('f') && !id.contains('-')) {
    return FilesId(base: null, fileKey: id.substring(1));
  }
  final parts = id.split('-');
  if (parts.length > 3) return null;
  final base = parts.first;
  final okBase = base.startsWith('p')
      ? RegExp(r'^p[0-9a-f]{16}$').hasMatch(base)
      : RegExp(r'^\d+$').hasMatch(base);
  if (!okBase) return null;
  final nums = [for (final p in parts.skip(1)) int.tryParse(p)];
  if (nums.contains(null)) return null;
  return FilesId(
    base: base,
    season: nums.isNotEmpty ? nums[0] : null,
    episode: nums.length > 1 ? nums[1] : null,
  );
}
