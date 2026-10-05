import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sources/sources_providers.dart';
import 'download_providers.dart';
import 'download_service.dart';

/// Deletes the downloads of accounts that no longer exist. Removing an account
/// cleans up its downloads on a best-effort basis (a bounded lookup, errors
/// caught), so a failed cleanup would leave downloads that no account could
/// ever retry. This is the retry.
///
/// It runs whenever a successfully loaded records snapshot has a different set
/// of account ids than the one it last swept with (the first load counts), so
/// an account removed mid-session is covered too. While the records are
/// loading, or if they failed to load, the known accounts are unknown, and
/// sweeping then would delete every third-party download. Runs never overlap:
/// a change that arrives during a run triggers one more run afterwards.
/// Mounted from AppShell, like `sourceProgressFlushProvider`. It lives apart
/// from `downloadManagerProvider` so that keep-alive provider never watches
/// the source providers.
final orphanDownloadSweepProvider = Provider<void>((ref) {
  if (!isDownloadSupported) return;
  Set<String>? sweptWith;
  var running = false;
  var again = false;

  /// The stored account ids, or null unless the records are loaded.
  Set<String>? knownAccountIds() {
    final records = ref.read(sourceRecordsProvider);
    if (records.isLoading || records.hasError) return null;
    final snapshot = records.value;
    if (snapshot == null) return null;
    return {for (final a in snapshot.accounts) a.account.id};
  }

  Future<void> sweepOnce() async {
    try {
      final manager = await ref.read(downloadManagerProvider.future);
      // Read after the await: the accounts may have changed while the manager
      // was starting, and a stale set would delete a new account's downloads.
      final known = knownAccountIds();
      if (known == null || setEquals(known, sweptWith)) return;
      final removed = await manager.deleteDownloadsOfUnknownAccounts(known);
      sweptWith = known;
      if (removed > 0) {
        debugPrint('[downloads] Removed $removed download(s) of '
            'accounts that no longer exist');
      }
    } catch (e) {
      // Best effort: the next change of the accounts tries again.
      debugPrint('[downloads] Orphan sweep failed: $e');
    }
  }

  Future<void> run() async {
    if (running) {
      again = true;
      return;
    }
    running = true;
    try {
      do {
        again = false;
        await sweepOnce();
      } while (again);
    } finally {
      running = false;
    }
  }

  ref.listen(sourceRecordsProvider, fireImmediately: true, (_, next) {
    final known = knownAccountIds();
    if (known == null || setEquals(known, sweptWith)) return;
    unawaited(run());
  });
});
