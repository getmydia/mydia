import 'dart:io';

/// Whether [error] indicates that another instance of the app already holds
/// an on-disk lock this process just tried to acquire.
///
/// Every persistent store the app opens at startup (the GraphQL Hive cache,
/// the fetch log, the download database) lives under the same per-user data
/// directory and is guarded by a `.lock` file. A second instance of the app
/// pointed at that same directory fails to open *all* of them with the same
/// underlying `FileSystemException`: a failed `lock()` call on a `.lock`
/// file, surfaced as `errno 35` (`EAGAIN`/`EWOULDBLOCK`) on POSIX platforms.
///
/// That is the one startup failure with a specific, user-actionable
/// explanation ("quit the other window") instead of being a generic error,
/// so it is worth detecting on its own rather than folding it into the
/// catch-all startup-failure path.
bool isLockContentionError(Object error) {
  if (error is! FileSystemException) return false;

  final looksLikeLockFile = (error.path ?? '').endsWith('.lock');

  const eagain = 35; // EAGAIN / EWOULDBLOCK
  final isResourceUnavailable = error.osError?.errorCode == eagain;

  return looksLikeLockFile || isResourceUnavailable;
}
