import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_media_source.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/peer_files_sources.dart';
import 'package:player/core/sources/current_source_status.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/l10n/gen/app_localizations_en.dart';
import 'package:player/l10n/formatters.dart';

import 'fake_backend.dart';
import 'files_fixture.dart';
import 'peer_files_harness.dart';

/// A backend whose play fails the way the test says.
class _FailingPlayBackend extends FakeBackend {
  _FailingPlayBackend(this.failure) : super({});

  BackendFailure failure;

  @override
  Future<PlayableFile> playable(String path) async => throw failure;
}

Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late PeerHarness h;
  final l10n = AppLocalizationsEn();

  setUp(() async {
    h = PeerHarness(await FilesFixture.create());
    await h.seed();
  });

  Future<(FilesMediaSource, String)> peerSource(BackendFailure failure) async {
    final lent = lentFlocal();
    h.backends[peerFilesSource(lent)] = _FailingPlayBackend(failure);
    h.client.list.value = [lent];
    final c = await h.container();
    addTearDown(c.dispose);
    final id = c.read(sourcesProvider).last.id;
    final media = c.read(mediaSourceProvider(id))! as FilesMediaSource;
    await _settle();
    final key = fileKeyFor('rhost', 'Quiet Meridian (2027).mkv');
    return (media, key);
  }

  Future<SourceException> playFailure(FilesMediaSource m, String key) async {
    try {
      await m.playableForFileKey(key);
    } on SourceException catch (e) {
      return e;
    }
    fail('play did not fail');
  }

  test('BackendUnreachable maps to peerFilesHostUnreachable', () async {
    final (m, key) = await peerSource(const BackendUnreachable('gone'));
    final e = await playFailure(m, key);
    expect(l10n.sourceError(e),
        "Den Desktop isn't reachable. It needs to be on with Mydia Player open.");
  });

  test('a 502 maps to peerFilesShareDown and keeps the status', () async {
    final (m, key) =
        await peerSource(const BackendUnreachable('answered 502', 502));
    final before = m.connection;
    final e = await playFailure(m, key);
    expect(l10n.sourceError(e), "Den Desktop can't reach its share right now.");
    expect(m.connection, before);
  });

  test('BackendNotFound maps to peerFilesFileGone and refreshes the host',
      () async {
    final (m, key) = await peerSource(const BackendNotFound());
    final e = await playFailure(m, key);
    expect(l10n.sourceError(e), 'This file is no longer on Den Desktop.');
    expect(h.client.refreshed, [hostNode]);
  });

  test('BackendUnauthorized refreshes the host', () async {
    final (m, key) = await peerSource(const BackendUnauthorized());
    final e = await playFailure(m, key);
    expect(e.kind, SourceErrorKind.unauthorized);
    expect(h.client.refreshed, [hostNode]);
  });

  test('unreachable_status_when_member_disconnected', () async {
    final lent = lentFlocal();
    final backend = FakeBackend({},
        probeFailure: const BackendUnreachable('peer not connected'));
    h.backends[peerFilesSource(lent)] = backend;
    h.client.list.value = [lent];
    final c = await h.container();
    addTearDown(c.dispose);
    final id = c.read(sourcesProvider).last.id;
    c.listen(sourceStatusProvider(id), (_, __) {});
    await _settle();
    expect(
        c.read(sourceStatusProvider(id)), SourceConnectionStatus.unreachable);

    backend.probeFailure = null;
    h.connected.add(hostNode);
    await _settle();
    expect(c.read(sourceStatusProvider(id)), SourceConnectionStatus.local);
  });
}
