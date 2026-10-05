import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sources/sources_providers.dart';
import 'download_providers.dart';
import 'download_service.dart';

/// Deletes the downloads of accounts that no longer exist, once per app
/// session. Removing an account cleans up its downloads on a best-effort
/// basis (a bounded lookup, errors caught), so a failed cleanup would leave
/// downloads that no account could ever retry. This is the retry.
///
/// It waits for the stored records to load successfully: while they are
/// loading, or if they failed to load, the known accounts are unknown, and
/// sweeping then would delete every third-party download. Mounted from
/// AppShell, like `sourceProgressFlushProvider`. It lives apart from
/// `downloadManagerProvider` so that keep-alive provider never watches the
/// source providers.
final orphanDownloadSweepProvider = Provider<void>((ref) {
  if (!isDownloadSupported) return;
  var started = false;

  Future<void> sweep(Set<String> knownAccountIds) async {
    try {
      final manager = await ref.read(downloadManagerProvider.future);
      final removed =
          await manager.deleteDownloadsOfUnknownAccounts(knownAccountIds);
      if (removed > 0) {
        debugPrint('[downloads] Removed $removed download(s) of '
            'accounts that no longer exist');
      }
    } catch (e) {
      // Best effort: the next launch tries again.
      debugPrint('[downloads] Orphan sweep failed: $e');
    }
  }

  ref.listen(sourceRecordsProvider, fireImmediately: true, (_, next) {
    if (started || next.hasError) return;
    final snapshot = next.value;
    if (snapshot == null) return;
    started = true;
    unawaited(sweep({for (final a in snapshot.accounts) a.account.id}));
  });
});
