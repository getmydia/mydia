import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/collection_sync_service.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/collections/collection_detail_screen.dart';

Future<AppLocalizations> _en() =>
    AppLocalizations.delegate.load(const Locale('en'));

void main() {
  test('failures are reported when nothing was queued, even with skips',
      () async {
    final l10n = await _en();
    const result = CollectionSyncResult(
        moviesQueued: 0, episodesQueued: 0, skipped: 2, failed: 3);
    final message = collectionSyncResultMessage(l10n, result);
    expect(message, l10n.collectionSyncNothingQueuedFailed(3, 2));
    expect(message, isNot(l10n.collectionSyncAllSkipped(2)));
  });

  test('all skipped with no failures keeps the skipped message', () async {
    final l10n = await _en();
    const result = CollectionSyncResult(
        moviesQueued: 0, episodesQueued: 0, skipped: 2, failed: 0);
    expect(collectionSyncResultMessage(l10n, result),
        l10n.collectionSyncAllSkipped(2));
  });

  test('queued items keep the queued message', () async {
    final l10n = await _en();
    const result = CollectionSyncResult(
        moviesQueued: 1, episodesQueued: 0, skipped: 0, failed: 1);
    expect(collectionSyncResultMessage(l10n, result),
        l10n.collectionSyncQueuedMovies(1, 0));
  });
}
