/// Web stub for `isLockContentionError`. See `startup_lock.dart`.
///
/// The web build cannot import `dart:io`, and has nothing to detect anyway:
/// each tab gets its own IndexedDB-backed Hive store rather than a shared
/// on-disk one, so two "instances" never contend for a lock file.
bool isLockContentionError(Object error) => false;
