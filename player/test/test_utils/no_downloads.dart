import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:player/core/downloads/collection_sync_providers.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/downloads/download_service_native.dart';

/// A download manager with no database, for tests that remove accounts. The
/// real one opens Hive, which a plain unit test has not initialised.
final Override noDownloadsOverride = downloadManagerProvider
    .overrideWith((ref) async => createNativeDownloadService());

/// Collection auto-sync with no box, for the same tests. Account removal
/// clears collection sync best effort, so a test that never initialised Hive
/// used to get an instant "not initialised" error here and carry on. CI runs
/// the suite as one bundle, where an earlier file may have initialised Hive
/// on a directory it then deleted, and `openBox` hangs instead. Failing fast
/// keeps the isolated behaviour on purpose.
final Override noCollectionSyncOverride = collectionSyncBoxProvider
    .overrideWith((ref) async => throw StateError('no collection sync box'));

/// Everything Hive-backed a test that removes accounts would otherwise open.
final List<Override> noHiveOverrides = [
  noDownloadsOverride,
  noCollectionSyncOverride,
];
