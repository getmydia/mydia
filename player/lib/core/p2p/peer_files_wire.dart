/// The files index as it travels to a paired player: each record is the
/// UTF-8 JSON of its own `toMap()`, read back with its `fromMap()`, so the
/// wire carries exactly what the index stores and the bridge never mirrors
/// the record shapes. Episodes ride inside [MatchedShow.toMap], so roots,
/// files, groups, movies and shows cover the whole index.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../native/lib.dart';
import '../sources/files/index/file_library_index.dart';

/// What the host fills one index page up to, matching
/// `PEER_FILES_PAGE_BUDGET` in `mydia_p2p_core`: half the 8 MiB response
/// cap, which leaves room for the page's own framing.
const peerFilesPageBudget = 4 * 1024 * 1024;

/// Allowance for the framing CBOR adds around each record's bytes: a byte
/// string header is at most 9 bytes.
const _recordOverhead = 9;

List<Uint8List> encodeJsonRecords<T>(
  Iterable<T> records,
  Map<String, dynamic> Function(T) toMap,
) =>
    [for (final r in records) _encode(toMap(r))];

List<T> decodeJsonRecords<T>(
  List<Uint8List> blobs,
  T Function(Map<dynamic, dynamic>) fromMap,
) =>
    [
      for (final b in blobs)
        fromMap(jsonDecode(utf8.decode(b)) as Map<dynamic, dynamic>),
    ];

Uint8List _encode(Map<String, dynamic> map) =>
    Uint8List.fromList(utf8.encode(jsonEncode(map)));

/// The index's records in wire order: roots, files, groups, movies, shows,
/// each sorted by its key so a cursor means the same record on every page
/// of one revision.
List<List<Map<String, dynamic> Function()>> _sections(FileLibraryIndex index) {
  final roots = index.roots()..sort((a, b) => a.id.compareTo(b.id));
  final files = index.files().values.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  final groups = index.groups()
    ..sort((a, b) => a.groupKey.compareTo(b.groupKey));
  final movies = index.movies()..sort((a, b) => a.tmdbId.compareTo(b.tmdbId));
  final shows = index.shows()..sort((a, b) => a.tmdbId.compareTo(b.tmdbId));
  return [
    [for (final r in roots) r.toMap],
    [for (final f in files) f.toMap],
    [for (final g in groups) g.toMap],
    [for (final m in movies) m.toMap],
    [for (final s in shows) s.toMap],
  ];
}

/// One page of [index] starting at record [start] (counted across roots,
/// files, groups, movies and shows in that order), filled up to [budget]
/// bytes, and the start of the next page, null after the last. A page
/// always holds at least one record, so a record larger than the budget
/// still goes out on a page of its own.
({FlutterWireIndexPage page, int? next}) indexPageFrom(
  FileLibraryIndex index,
  int start, {
  int budget = peerFilesPageBudget,
}) {
  final sections = _sections(index);
  final out = [for (final _ in sections) <Uint8List>[]];
  var used = 0;
  var taken = 0;
  var position = 0;
  int? next;
  outer:
  for (var s = 0; s < sections.length; s++) {
    final section = sections[s];
    for (var i = max(0, start - position); i < section.length; i++) {
      final bytes = _encode(section[i]());
      final cost = bytes.length + _recordOverhead;
      if (taken > 0 && used + cost > budget) {
        next = position + i;
        break outer;
      }
      out[s].add(bytes);
      used += cost;
      taken++;
    }
    position += section.length;
  }
  return (
    page: FlutterWireIndexPage(
      roots: out[0],
      files: out[1],
      groups: out[2],
      movies: out[3],
      shows: out[4],
    ),
    next: next,
  );
}

/// Every page of [index] in order, as a host would serve them.
List<FlutterWireIndexPage> pageIndex(
  FileLibraryIndex index, {
  int budget = peerFilesPageBudget,
}) {
  final pages = <FlutterWireIndexPage>[];
  int? start = 0;
  while (start != null) {
    final slice = indexPageFrom(index, start, budget: budget);
    pages.add(slice.page);
    start = slice.next;
  }
  return pages;
}
