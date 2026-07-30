import 'dart:io';

/// Native implementation of `isLockContentionError`. See `startup_lock.dart`
/// for what this detects and why it is worth detecting separately.
bool isLockContentionError(Object error) {
  if (error is! FileSystemException) return false;

  final looksLikeLockFile = (error.path ?? '').endsWith('.lock');

  final code = error.osError?.errorCode;
  final isLockAlreadyHeld = code != null && _lockContentionCodes.contains(code);

  return looksLikeLockFile || isLockAlreadyHeld;
}

/// The OS error codes *this* platform reports when a lock is already held.
///
/// `EAGAIN`/`EWOULDBLOCK` — what a failed non-blocking `flock()` returns, and
/// what the reproduced macOS bug surfaced as — is not a portable number: it
/// is 35 on Darwin and the BSDs but 11 on Linux. Windows does not report an
/// errno here at all; a contended `LockFileEx` comes back as
/// `ERROR_SHARING_VIOLATION` (32) or `ERROR_LOCK_VIOLATION` (33).
///
/// Matching a bare number on every platform would misfire, because each of
/// these values means something unrelated elsewhere (35 is `EDEADLK` on
/// Linux, 33 is `EDOM` on both Linux and Darwin), so only the running
/// platform's own codes count.
Set<int> get _lockContentionCodes {
  if (Platform.isLinux || Platform.isAndroid) return const {11};
  if (Platform.isWindows) return const {32, 33};
  // Darwin (macOS, iOS) and the BSDs.
  return const {35};
}
