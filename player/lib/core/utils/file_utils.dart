/// Platform-safe file utilities.
///
/// On web, file operations are not supported and return false/null.
library;

import 'file_utils_stub.dart' if (dart.library.io) 'file_utils_native.dart'
    as impl;

/// Check if a local file exists.
/// Returns false on web since local file access is not supported.
Future<bool> fileExists(String path) => impl.fileExists(path);
