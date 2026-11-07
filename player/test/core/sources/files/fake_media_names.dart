import 'package:player/core/sources/files/media_names.dart';

/// Deterministic stand-in for [RustMediaNames]: `S01E02` names are episodes,
/// everything else is a movie. Either takes an optional `(yyyy)` year, and
/// groups by title and year, episodes under a `tv:` prefix, as the Rust
/// parser does.
class FakeMediaNames implements MediaNames {
  /// Every path ever passed to [parseBatch], in order.
  final List<String> parsedPaths = [];

  static final _episode =
      RegExp(r'^(.*?)[\s._-]*S(\d+)E(\d+)', caseSensitive: false);
  static final _year = RegExp(r'\((\d{4})\)');

  static String _alnum(String s) =>
      s.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  @override
  List<ParsedName> parseBatch(
    String root,
    List<String> paths,
    FilesLibraryKind kind,
  ) {
    final out = <ParsedName>[];
    for (final path in paths) {
      parsedPaths.add(path);
      final stem = _stem(path);
      final ep = _episode.firstMatch(stem);
      if (ep != null) {
        final show = ep.group(1)!;
        final y = _year.firstMatch(show);
        final title = (y == null ? show : show.substring(0, y.start)).trim();
        final year = y == null ? null : int.parse(y.group(1)!);
        out.add(
          ParsedName(
            path: path,
            isEpisode: true,
            title: title,
            year: year,
            season: int.parse(ep.group(2)!),
            episode: int.parse(ep.group(3)!),
            groupKey: 'tv:${_alnum(title)}|${year ?? ''}',
          ),
        );
        continue;
      }
      final y = _year.firstMatch(stem);
      final title = (y == null ? stem : stem.substring(0, y.start)).trim();
      if (title.isEmpty) continue;
      final year = y == null ? null : int.parse(y.group(1)!);
      out.add(
        ParsedName(
          path: path,
          isEpisode: false,
          title: title,
          year: year,
          groupKey: '${_alnum(title)}|${year ?? ''}',
        ),
      );
    }
    return out;
  }

  @override
  TmdbMatch? score(
    String title,
    int? year, {
    required bool isShow,
    required List<TmdbCandidate> candidates,
  }) {
    final wanted = _alnum(title);
    for (final c in candidates) {
      if (_alnum(c.title) == wanted) {
        return TmdbMatch(id: c.id, confidence: 1);
      }
    }
    return null;
  }

  static String _stem(String path) {
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}
