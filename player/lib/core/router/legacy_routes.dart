/// Where the unprefixed pre-instance locations live now.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sources/mydia/bound_mydia.dart';
import '../sources/source.dart';
import '../sources/sources_providers.dart';
import '../sources/store/source_records.dart';

const _listings = {
  'favorites',
  'unwatched',
  'recently-added',
  'continue-watching',
  'calendar',
  'collections',
};

const _details = {'movie', 'show', 'episode'};

/// Where an unprefixed pre-instance location now lives, or null when
/// [uri] is not one. [legacy] is the migrated instance's source, [mydia] every
/// Mydia instance's source, [active] the source `/` and `/search` open.
String? legacyLocation(
  Uri uri, {
  required SourceId? legacy,
  required List<SourceId> mydia,
  required SourceId? active,
}) {
  final seg = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  final query = uri.hasQuery ? uri.queryParametersAll : null;

  String build(List<String> segments, [Map<String, List<String>>? q]) {
    final params = q ?? query;
    return Uri(
      pathSegments: ['', ...segments],
      queryParameters: params == null || params.isEmpty ? null : params,
    ).toString();
  }

  // The migrated instance when it still exists, else the only Mydia one.
  final SourceId? target = legacy != null && mydia.contains(legacy)
      ? legacy
      : (mydia.length == 1 ? mydia.single : null);
  String move(List<String> rest, [Map<String, List<String>>? q]) =>
      target == null
          ? '/sources/manage'
          : build(['s', target.value, ...rest], q);

  if (seg.isEmpty) {
    return active == null ? null : build(['s', active.value], const {});
  }
  switch (seg) {
    case ['search']:
      return active == null ? null : build(['s', active.value, 'search']);
    case ['movies'] || ['shows']:
      return move(['library', seg.first]);
    case [final p] when _listings.contains(p):
      return move([p]);
    case ['filter', final id]:
      return move(['filter', id]);
    case ['collection', final id]:
      return move(['collection', id]);
    case [final kind, final id] when _details.contains(kind):
      return move([kind, id]);
    case ['player', final type, final id] when type != 'queue':
      return move([
        'player',
        id
      ], {
        ...?query,
        'kind': [type]
      });
    case ['settings', 'devices']:
      return target == null
          ? '/sources/manage'
          : build(['sources', 'manage', target.value], const {});
  }
  return null;
}

/// The migrated instance's source, while its account exists.
final legacyMydiaSourceIdProvider = Provider<SourceId?>((ref) {
  final snapshot = ref.watch(sourceRecordsProvider).value;
  final legacy = ref.watch(legacyInstanceIdProvider).value;
  if (snapshot == null || legacy == null) return null;
  for (final r in snapshot.accounts) {
    if (r.account.kind == SourceKind.mydia && r.account.id == legacy) {
      return mydiaSourceIdOf(r);
    }
  }
  return null;
});

/// The ids as one string, so a record write that changes no id compares equal
/// and does not notify. Ids hold no newline.
final _mydiaSourceIdKeyProvider = Provider<String>((ref) {
  final snapshot = ref.watch(sourceRecordsProvider).value;
  if (snapshot == null) return '';
  final mydia = [
    for (final r in snapshot.accounts)
      if (r.account.kind == SourceKind.mydia) r,
  ]..sort((a, b) => a.addedAtMs.compareTo(b.addedAtMs));
  return [for (final r in mydia) mydiaSourceIdOf(r).value].join('\n');
});

/// Every Mydia instance's source, in the order added. Notifies only when the
/// ids change, not on every source-records write (a picker switch, a reauth
/// flag), so what is built per instance is not torn down for nothing.
final mydiaSourceIdsProvider = Provider<List<SourceId>>((ref) {
  final key = ref.watch(_mydiaSourceIdKeyProvider);
  if (key.isEmpty) return const [];
  return [for (final id in key.split('\n')) SourceId(id)];
});
