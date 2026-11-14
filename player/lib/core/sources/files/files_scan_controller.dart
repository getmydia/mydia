/// Scans of a files library: every root, then matching, with progress the
/// scan banner reads.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cache/watcher_registry.dart' show invalidatorProvider;
import '../../p2p/peer_files_host.dart' show peerFilesHostProvider;
import '../connection/app_foreground.dart';
import '../source.dart';
import '../sources_providers.dart' show mediaSourceProvider;
import 'backend/file_system_backend.dart';
import 'files_media_source.dart';
import 'files_providers.dart';
import 'media_names.dart';
import 'peer_files_sources.dart' show isPeerFilesSource;
import 'scan/file_scanner.dart';

@immutable
class ScanState {
  const ScanState({
    this.running = false,
    this.done = 0,
    this.total = 0,
    this.error,
    this.skippedCount = 0,
    this.walking = false,
    this.foldersRead = 0,
  });

  final bool running;

  /// The folders of a root are still being listed, so [total] does not
  /// count its files yet. Over a network share this is most of the run.
  final bool walking;

  /// Folders listed so far in this run, over every root.
  final int foldersRead;

  /// Folders and files the last run could not read and left out, over
  /// every root.
  final int skippedCount;

  /// Files handled so far, over every root scanned in this run.
  final int done;
  final int total;

  /// The last failure of the run (a root that could not be read), if any.
  /// The other roots are still scanned.
  final Object? error;
}

final filesScanProvider =
    NotifierProvider.family<FilesScanController, ScanState, SourceId>(
        FilesScanController.new);

class FilesScanController extends Notifier<ScanState> {
  FilesScanController(this.sourceId);

  final SourceId sourceId;
  Future<void>? _running;
  Future<void>? _queued;

  @override
  ScanState build() => const ScanState();

  /// Scans every root, then matches what is new, then records the scan time.
  /// A call while a scan runs queues one more pass after it, since the
  /// running one read its roots before a folder just added; further calls
  /// join that queued pass.
  Future<void> rescan() {
    final running = _running;
    if (running == null) {
      return _running = _run().whenComplete(() => _running = null);
    }
    return _queued ??= running.then((_) {
      _queued = null;
      return rescan();
    });
  }

  Future<void> _run() async {
    final media = ref.read(mediaSourceProvider(sourceId));
    if (media is! FilesMediaSource) return;
    // A lent library's index is the host's copy, which its host scans.
    if (isPeerFilesSource(media.source)) return;
    final index = media.index;
    final scanner = FileScanner(
      backend: media.backend,
      names: ref.read(mediaNamesProvider),
      index: index,
      foreground: ref.read(appForegroundProvider),
    );
    final invalidator = ref.read(invalidatorProvider);
    final now = ref.read(filesClockProvider);
    state = const ScanState(running: true);

    // Every failure is recorded, never thrown: the scan is started unawaited,
    // and the final state must always land so the banner stops.
    Object? error;
    BackendFailure? unreachable;
    var before = 0;
    var latest = (done: 0, total: 0);
    var skipped = 0;
    var foldersBefore = 0;
    var folders = 0;
    void report({required bool walking}) {
      if (!ref.mounted) return;
      state = ScanState(
        running: true,
        walking: walking,
        done: latest.done,
        total: latest.total,
        foldersRead: folders,
      );
    }

    final clock = Stopwatch()..start();
    try {
      final roots = index.roots();
      debugPrint('[FilesScan] $sourceId: scanning ${roots.length} folders '
          '(${roots.map((r) => '${r.id} ${r.kind.name} ${r.path}').join('; ')})'
          ', last scan ${index.lastScanAt()?.toIso8601String() ?? 'never'}');
      var scanned = 0;
      for (final root in roots) {
        final rootClock = Stopwatch()..start();
        // The root's first listing can take a while: say so before it lands
        // rather than keep showing the previous root's count.
        report(walking: true);
        try {
          final delta = await scanner.scan(
            root,
            onFolderRead: (n) {
              folders = foldersBefore + n;
              report(walking: true);
            },
            onProgress: (done, total) {
              latest = (done: before + done, total: before + total);
              report(walking: false);
            },
          );
          skipped += delta.skippedPaths.length;
          scanned++;
          debugPrint('[FilesScan] ${root.id} scanned in '
              '${rootClock.elapsed.inSeconds}s: ${delta.added.length} added, '
              '${delta.changed.length} changed, '
              '${delta.removedKeys.length} removed, '
              '${delta.skippedPaths.length} skipped');
        } on BackendFailure catch (e) {
          debugPrint('[FilesScan] ${root.id} not scanned after '
              '${rootClock.elapsed.inSeconds}s: $e');
          error = e;
          if (unreachable == null || e is BackendPermissionLost) {
            unreachable = e;
          }
        } catch (e) {
          debugPrint('[FilesScan] ${root.id} failed: $e');
          error = e;
        }
        before = latest.total;
        foldersBefore = folders;
      }
      media.reportReachability(unreachable);
      try {
        await media.matcher.matchPending();
      } catch (e) {
        debugPrint('[FilesScan] Matching failed: $e');
        error ??= e;
      }
      // A run where every root failed (an unplugged drive, a share that is
      // down) is not a scan: leave the time alone so the next open tries
      // again instead of waiting out the rescan interval.
      if (roots.isEmpty || scanned > 0) {
        await index.setLastScanAt(now());
        // Paired players browsing this library refetch it.
        await ref
            .read(peerFilesHostProvider)
            .bumpRevision(media.source.account.id);
      }
      await invalidator
          .invalidate(FilesMediaSource.groupLandedTargets(sourceId));
      final files = index.files().values;
      final perRoot = {
        for (final r in roots) r.id: files.where((f) => f.rootId == r.id).length
      };
      debugPrint('[FilesScan] $sourceId: done in ${clock.elapsed.inSeconds}s, '
          '$scanned of ${roots.length} folders scanned, ${files.length} files '
          'indexed $perRoot, ${files.where((f) => f.parsed == null).length} '
          'with names that did not parse');
    } catch (e) {
      debugPrint('[FilesScan] Scan failed: $e');
      error ??= e;
    } finally {
      if (ref.mounted) {
        state = ScanState(
          done: latest.done,
          total: latest.total,
          error: error,
          skippedCount: skipped,
          foldersRead: folders,
        );
      }
    }
  }
}
