import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/downloads/download_service_native.dart';

/// A download manager with no database, for tests that remove accounts. The
/// real one opens Hive, which a plain unit test has not initialised.
final Override noDownloadsOverride = downloadManagerProvider
    .overrideWith((ref) async => createNativeDownloadService());
