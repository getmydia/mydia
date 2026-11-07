/// Scans of a files library: every root, then matching, with progress the
/// scan banner reads.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cache/watcher_registry.dart' show invalidatorProvider;
import '../source.dart';
import '../sources_providers.dart' show mediaSourceProvider;
import 'backend/file_system_backend.dart';
import 'files_media_source.dart';
import 'files_providers.dart';
import 'media_names.dart';
import 'scan/file_scanner.dart';

@immutable
class ScanState {
  const ScanState({
    this.running = false,
    this.done = 0,
    this.total = 0,
    this.error,
    this.skippedFolders = 0,
  });

  final bool running;

  /// Folders the last run could not read and left out, over every root.
  final int skippedFolders;

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
    final index = media.index;
    final scanner = FileScanner(
      backend: media.backend,
      names: ref.read(mediaNamesProvider),
      index: index,
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
    try {
      final roots = index.roots();
      var scanned = 0;
      for (final root in roots) {
        try {
          final delta = await scanner.scan(root, onProgress: (done, total) {
            latest = (done: before + done, total: before + total);
            if (ref.mounted) {
              state = ScanState(
                  running: true, done: latest.done, total: latest.total);
            }
          });
          skipped += delta.skippedFolders.length;
          scanned++;
        } on BackendFailure catch (e) {
          debugPrint('[FilesScan] ${root.id} not scanned: $e');
          error = e;
          if (unreachable == null || e is BackendPermissionLost) {
            unreachable = e;
          }
        } catch (e) {
          debugPrint('[FilesScan] ${root.id} failed: $e');
          error = e;
        }
        before = latest.total;
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
      if (roots.isEmpty || scanned > 0) await index.setLastScanAt(now());
      await invalidator
          .invalidate(FilesMediaSource.groupLandedTargets(sourceId));
    } catch (e) {
      debugPrint('[FilesScan] Scan failed: $e');
      error ??= e;
    } finally {
      if (ref.mounted) {
        state = ScanState(
          done: latest.done,
          total: latest.total,
          error: error,
          skippedFolders: skipped,
        );
      }
    }
  }
}
