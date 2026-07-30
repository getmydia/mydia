import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/startup/startup_lock.dart';
import 'package:player/core/startup/startup_lock_stub.dart' as web_stub;

/// The code this platform reports for a lock that is already held, mirroring
/// the table in `startup_lock_native.dart`: `EAGAIN` is 11 on Linux and 35 on
/// Darwin, and Windows reports `ERROR_LOCK_VIOLATION` instead.
int get lockHeldCode {
  if (Platform.isLinux || Platform.isAndroid) return 11;
  if (Platform.isWindows) return 33;
  return 35;
}

/// A code that means "lock already held" on *some other* platform but not
/// this one, so it must not be matched here.
int get foreignLockHeldCode => lockHeldCode == 11 ? 35 : 11;

void main() {
  group('isLockContentionError', () {
    test('detects the reproduced two-instance failure', () {
      final error = FileSystemException(
        'lock failed',
        '/Users/someone/Documents/graphqlclientstore.lock',
        OSError('Resource temporarily unavailable', lockHeldCode),
      );

      expect(isLockContentionError(error), isTrue);
    });

    test('detects a .lock path even without an OSError attached', () {
      const error = FileSystemException(
        'lock failed',
        '/Users/someone/Documents/download_tasks.lock',
      );

      expect(isLockContentionError(error), isTrue);
    });

    test('detects this platform\'s code on a path without a .lock suffix', () {
      final error = FileSystemException(
        'lock failed',
        '/Users/someone/Documents/mydia_fetch_log',
        OSError('Resource temporarily unavailable', lockHeldCode),
      );

      expect(isLockContentionError(error), isTrue);
    });

    test('ignores another platform\'s code on a path without a .lock suffix',
        () {
      // The same number means something unrelated here (e.g. 35 is EDEADLK on
      // Linux, 11 is EDEADLK on Darwin), so it must not be read as contention.
      final error = FileSystemException(
        'something else went wrong',
        '/Users/someone/Documents/mydia_fetch_log',
        OSError('Some other failure', foreignLockHeldCode),
      );

      expect(isLockContentionError(error), isFalse);
    });

    test('does not flag an unrelated FileSystemException', () {
      const error = FileSystemException(
        'No such file or directory',
        '/Users/someone/Documents/missing.txt',
        OSError('No such file or directory', 2),
      );

      expect(isLockContentionError(error), isFalse);
    });

    test('does not flag a non-FileSystemException error', () {
      expect(isLockContentionError(Exception('boom')), isFalse);
      expect(isLockContentionError(StateError('boom')), isFalse);
    });
  });

  group('web stub', () {
    // The stub is what the web build compiles against in place of the
    // `dart:io` implementation; a browser tab has no shared lock to contend
    // for, so it answers false for everything.
    test('never reports lock contention', () {
      const lockError = FileSystemException(
        'lock failed',
        '/Users/someone/Documents/graphqlclientstore.lock',
        OSError('Resource temporarily unavailable', 35),
      );

      expect(web_stub.isLockContentionError(lockError), isFalse);
      expect(web_stub.isLockContentionError(Exception('boom')), isFalse);
    });
  });
}
