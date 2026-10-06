import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../router/legacy_routes.dart';
import '../sources/capabilities.dart';
import '../sources/source.dart';
import '../sources/sources_providers.dart';
import 'remote_roster.dart';

/// Every Mydia instance's roster as one. A device known to several
/// instances is listed once, by p2p node id, which is the identity a
/// device shares across instances.
class MergedRoster implements DeviceRoster {
  MergedRoster(Map<SourceId, DeviceRoster> rosters)
      : _rosters = Map.unmodifiable(rosters);

  final Map<SourceId, DeviceRoster> _rosters;

  @override
  Future<List<RemoteDeviceEntry>> entries() =>
      _merged((roster) => roster.entries());

  @override
  Future<List<RemoteDeviceEntry>> onlineEntries() =>
      _merged((roster) => roster.onlineEntries());

  @override
  Future<bool> allows(String peerNodeId) async {
    final answers = await Future.wait(
      _rosters.values.map((roster) async {
        try {
          return await roster.allows(peerNodeId);
        } catch (_) {
          return false;
        }
      }),
    );
    return answers.any((allowed) => allowed);
  }

  /// The instances whose roster lists [nodeId], in roster order.
  Future<List<SourceId>> instancesOf(String nodeId) async {
    final wanted = nodeId.toLowerCase();
    final lists = await _perRoster((roster) => roster.entries());
    return [
      for (final (id, entries) in lists)
        if (entries.any((e) => e.nodeId.toLowerCase() == wanted)) id,
    ];
  }

  Future<List<RemoteDeviceEntry>> _merged(
    Future<List<RemoteDeviceEntry>> Function(DeviceRoster) read,
  ) async {
    final seen = <String>{};
    return [
      for (final (_, entries) in await _perRoster(read))
        for (final entry in entries)
          if (seen.add(entry.nodeId.toLowerCase())) entry,
    ];
  }

  /// Queries every roster concurrently; one that throws yields no entries.
  Future<List<(SourceId, List<RemoteDeviceEntry>)>> _perRoster(
    Future<List<RemoteDeviceEntry>> Function(DeviceRoster) read,
  ) {
    return Future.wait([
      for (final MapEntry(:key, :value) in _rosters.entries)
        () async {
          try {
            return (key, await read(value));
          } catch (_) {
            return (key, const <RemoteDeviceEntry>[]);
          }
        }(),
    ]);
  }
}

/// A [DeviceRoster] that always asks [current], for a long-lived consumer
/// (the control receiver) that must see instances added after it was built.
class CurrentDeviceRoster implements DeviceRoster {
  CurrentDeviceRoster(this._current);

  final MergedRoster Function() _current;

  @override
  Future<List<RemoteDeviceEntry>> entries() => _current().entries();

  @override
  Future<List<RemoteDeviceEntry>> onlineEntries() => _current().onlineEntries();

  @override
  Future<bool> allows(String peerNodeId) => _current().allows(peerNodeId);
}

/// The rosters of every Mydia instance, as one.
final mergedRosterProvider = Provider<MergedRoster>((ref) {
  final rosters = <SourceId, DeviceRoster>{};
  for (final id in ref.watch(mydiaSourceIdsProvider)) {
    final roster =
        ref.watch(mediaSourceProvider(id))?.as<RemoteTargets>()?.roster;
    if (roster != null) rosters[id] = roster;
  }
  return MergedRoster(rosters);
});
