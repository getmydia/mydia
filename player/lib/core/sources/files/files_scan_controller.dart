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
  });

  final bool running;

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

  @override
  ScanState build() => const ScanState();

  /// Scans every root, then matches what is new, then records the scan time.
  /// A call while a scan runs joins it.
  Future<void> rescan() => _running ??= _run().whenComplete(() {
        _running = null;
      });

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

    Object? error;
    var before = 0;
    var latest = (done: 0, total: 0);
    for (final root in index.roots()) {
      try {
        await scanner.scan(root, onProgress: (done, total) {
          latest = (done: before + done, total: before + total);
          if (ref.mounted) {
            state = ScanState(
                running: true, done: latest.done, total: latest.total);
          }
        });
      } on BackendFailure catch (e) {
        debugPrint('[FilesScan] ${root.id} not scanned: $e');
        error = e;
      }
      before = latest.total;
    }
    try {
      await media.matcher.matchPending();
    } catch (e) {
      debugPrint('[FilesScan] Matching failed: $e');
      error ??= e;
    }
    await index.setLastScanAt(now());
    await invalidator.invalidate(FilesMediaSource.groupLandedTargets(sourceId));
    if (ref.mounted) {
      state = ScanState(done: latest.done, total: latest.total, error: error);
    }
  }
}
