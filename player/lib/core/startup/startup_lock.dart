/// Detection for the "another instance already holds our on-disk locks"
/// startup failure.
///
/// The check is inherently `dart:io`-shaped — it inspects a
/// `FileSystemException`, and has to consult `Platform` to know which OS
/// error code means "already locked" — so it lives in a native-only
/// implementation, with a stub for web.
///
/// Importing `dart:io` on web compiles (dart2js patches the library rather
/// than omitting it), but `Platform.isLinux` and friends throw
/// `UnsupportedError` there, so the split is load-bearing rather than
/// cosmetic. Web has nothing to detect regardless: a browser tab gets its
/// own IndexedDB-backed store, not a shared lock file.
library;

import 'startup_lock_stub.dart' if (dart.library.io) 'startup_lock_native.dart'
    as impl;

/// Whether [error] indicates that another instance of the app already holds
/// an on-disk lock this process just tried to acquire.
///
/// Every persistent store the app opens at startup (the GraphQL Hive cache,
/// the fetch log, the download database) lives under the same per-user data
/// directory and is guarded by a `.lock` file. A second instance of the app
/// pointed at that same directory fails to open *all* of them with the same
/// underlying `FileSystemException`: a failed `lock()` call on a `.lock`
/// file, surfaced as `EAGAIN`/`EWOULDBLOCK`.
///
/// That is the one startup failure with a specific, user-actionable
/// explanation ("quit the other window") instead of being a generic error,
/// so it is worth detecting on its own rather than folding it into the
/// catch-all startup-failure path.
///
/// Always `false` on web, which has no such lock to contend for.
bool isLockContentionError(Object error) => impl.isLockContentionError(error);
