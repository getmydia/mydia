import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/media_session/playing_source.dart';
import 'package:player/core/player/media_probe.dart';
import 'package:player/core/player/mpv_probe_mapping.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_media_source.dart';
import 'package:player/core/sources/files/files_providers.dart';
import 'package:player/core/sources/files/match/file_matcher.dart';
import 'package:player/core/sources/files/media_info/files_media_info_cache.dart';
import 'package:player/core/sources/files/media_info/files_probe_queue.dart';
import 'package:player/core/sources/files/peer_files_sources.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/models/media_stream.dart';

import '../fake_backend.dart';
import '../fake_media_names.dart';
import '../files_fixture.dart';
import '../peer_files_harness.dart' show lentFlocal;

const _probed = ProbeResult(
  container: 'matroska',
  durationSeconds: 5400,
  streams: [MediaStream(type: MediaStreamType.video, codec: 'hevc')],
);

/// A probe that records how many reads overlap. While [gate] is set, each
/// read waits on it.
class _TrackingProbe implements MediaProbe {
  final probed = <String>[];
  int inFlight = 0;
  int maxInFlight = 0;
  Completer<void>? gate;

  @override
  Future<ProbeResult?> probe(
    PlayableFile playable, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    probed.add(playable.url);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      final g = gate;
      if (g != null) await g.future;
      await Future<void>.delayed(Duration.zero);
      return _probed;
    } finally {
      inFlight--;
    }
  }
}

class _Rig {
  _Rig(this.f, this.c, this.media, this.probe, this.cache);

  final FilesFixture f;
  final ProviderContainer c;
  final FilesMediaSource media;
  final _TrackingProbe probe;
  final FilesMediaInfoCache cache;

  SourceId get id => media.id;
  String get account => media.source.account.id;

  FilesProbeQueue get queue => c.read(filesProbeQueueProvider(id).notifier);
  ProbeProgress get progress => c.read(filesProbeQueueProvider(id));

  /// Index keys whose cache entry is fresh.
  Set<String> get cached => {
        for (final file in f.index.files().values)
          if (cache.get(account, file) != null) file.key,
      };
}

Future<_Rig> _rig(
    {bool desktop = true, Source source = filesLocalSource}) async {
  final f = await FilesFixture.create();
  final relay = FakeFilesRelay();
  final probe = _TrackingProbe();
  final cache = await f.mediaInfoCache();
  final media = FilesMediaSource(
    source: source,
    backend: FakeBackend(const {}),
    index: f.index,
    progress: f.progress,
    matcher: FileMatcher(
      tmdb: relay,
      names: FakeMediaNames(),
      index: f.index,
      progress: f.progress,
      sourceId: source.id,
    ),
    tmdb: relay,
    l10n: () => filesL10n,
    probe: probe,
    mediaInfoCache: cache,
  );
  var disposed = false;
  addTearDown(() {
    if (!disposed) media.dispose();
  });
  final c = ProviderContainer(overrides: [
    mediaSourceProvider(source.id).overrideWith((ref) => media),
    filesMediaInfoCacheProvider.overrideWithValue(cache),
    filesProbeDesktopProvider.overrideWithValue(desktop),
    filesProbeIdlePollProvider.overrideWithValue(Duration.zero),
  ]);
  addTearDown(() {
    c.dispose();
    // The source the test disposed itself is not disposed again.
    disposed = disposed || !FilesMediaSource.activeSources.contains(media);
  });
  return _Rig(f, c, media, probe, cache);
}

Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('probes every stale file after enqueue on desktop, one at a time',
      () async {
    final r = await _rig();
    final all = r.f.index.files().keys.toSet();

    await r.queue.enqueueStale();

    expect(r.probe.probed, hasLength(all.length));
    expect(r.probe.probed.toSet(), hasLength(all.length));
    expect(r.probe.maxInFlight, 1);
    expect(r.cached, all);
  });

  test('does nothing when not desktop', () async {
    final r = await _rig(desktop: false);
    await r.queue.enqueueStale();
    expect(r.probe.probed, isEmpty);
    expect(r.progress.running, isFalse);
    expect(r.cached, isEmpty);
  });

  test('does nothing for a peer source', () async {
    final lent = peerFilesSource(lentFlocal());
    expect(isPeerFilesSource(lent), isTrue);
    final r = await _rig(source: lent);
    await r.queue.enqueueStale();
    expect(r.probe.probed, isEmpty);
    expect(r.progress.running, isFalse);
  });

  test('skips files with a fresh cache entry', () async {
    final r = await _rig();
    final files = r.f.index.files().values.toList();
    for (final file in files.take(2)) {
      await r.cache.put(r.account, file, _probed);
    }

    await r.queue.enqueueStale();

    expect(r.probe.probed, hasLength(files.length - 2));
    expect(r.progress.total, files.length - 2);
    expect(r.cached, hasLength(files.length));
  });

  test(
      'waits while playingSourceProvider.current is set, resumes after release',
      () async {
    final r = await _rig();
    final playing = r.c.read(playingSourceProvider);
    final owner = Object();
    playing.claim(owner, r.id);

    final run = r.queue.enqueueStale();
    await _settle();
    expect(r.probe.probed, isEmpty);
    expect(r.progress.running, isTrue);

    playing.release(owner);
    await run;
    expect(r.probe.probed, hasLength(r.f.index.files().length));
  });

  test('a second enqueue replaces the pending list', () async {
    final r = await _rig();
    final gate = Completer<void>();
    r.probe.gate = gate;

    final run = r.queue.enqueueStale();
    await _settle();
    expect(r.probe.probed, hasLength(1));
    final inFlight = r.probe.probed.single.replaceFirst('fake://', '');

    // Everything but the file being read and one more is read elsewhere
    // (an opened panel) before the next scan's enqueue.
    final files = r.f.index.files().values.toList();
    final first = files.firstWhere((f) => inFlight.endsWith(f.path));
    final other = files.firstWhere((f) => f.key != first.key);
    for (final file in files) {
      if (file.key != first.key && file.key != other.key) {
        await r.cache.put(r.account, file, _probed);
      }
    }
    final again = r.queue.enqueueStale();
    expect(r.progress.total, 2);

    gate.complete();
    await Future.wait([run, again]);
    // The file read while the list was replaced is fresh when its turn
    // comes again, so only the other one is read.
    expect(r.probe.probed, hasLength(2));
    expect(r.probe.probed.last, endsWith(other.path));
    expect(r.progress.done, 2);
    expect(r.progress.running, isFalse);
  });

  test('stops and writes nothing after the source is no longer active',
      () async {
    final r = await _rig();
    final playing = r.c.read(playingSourceProvider);
    final owner = Object();
    playing.claim(owner, r.id);

    final run = r.queue.enqueueStale();
    await _settle();
    // The library is removed while the queue waits out playback.
    r.media.dispose();
    expect(FilesMediaSource.activeSources, isNot(contains(r.media)));
    playing.release(owner);
    await run;

    expect(r.probe.probed, isEmpty);
    expect(r.cached, isEmpty);
    expect(r.progress.running, isFalse);
  });

  test('a source removed during the playback wait ends the run', () async {
    final r = await _rig();
    final playing = r.c.read(playingSourceProvider);
    final owner = Object();
    playing.claim(owner, r.id);

    final run = r.queue.enqueueStale();
    await _settle();
    expect(r.progress.running, isTrue);

    r.media.dispose();
    await run;

    // Playback never ended.
    expect(playing.current, isNotNull);
    expect(r.probe.probed, isEmpty);
    expect(r.progress.running, isFalse);
    playing.release(owner);
  });

  test('an enqueue with nothing stale keeps the numbers of the run', () async {
    final r = await _rig();
    final gate = Completer<void>();
    r.probe.gate = gate;
    final total = r.f.index.files().length;

    final run = r.queue.enqueueStale();
    await _settle();
    for (final file in r.f.index.files().values) {
      await r.cache.put(r.account, file, _probed);
    }

    final again = r.queue.enqueueStale();
    expect(r.progress.running, isTrue);
    expect(r.progress.total, total);
    expect(r.progress.total, isNot(0));

    gate.complete();
    await Future.wait([run, again]);
    expect(r.progress.running, isFalse);
  });

  test('progress counts done of total and clears running at the end', () async {
    final r = await _rig();
    final total = r.f.index.files().length;
    final states = <ProbeProgress>[];
    r.c.listen(filesProbeQueueProvider(r.id), (_, s) => states.add(s));

    await r.queue.enqueueStale();

    expect(states.first.running, isTrue);
    expect(states.first.total, total);
    expect(states.first.done, 0);
    expect(states.map((s) => s.done),
        orderedEquals([...states.map((s) => s.done)]..sort()));
    expect(
        states.where((s) => s.running).every((s) => s.total == total), isTrue);
    expect(states.last.running, isFalse);
    expect((states.last.done, states.last.total), (total, total));
  });
}
