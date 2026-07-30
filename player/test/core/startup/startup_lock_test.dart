import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/startup/startup_lock.dart';

void main() {
  group('isLockContentionError', () {
    test('detects the reproduced two-instance failure', () {
      const error = FileSystemException(
        'lock failed',
        '/Users/someone/Documents/graphqlclientstore.lock',
        OSError('Resource temporarily unavailable', 35),
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

    test('detects errno 35 even on a path without a .lock suffix', () {
      const error = FileSystemException(
        'lock failed',
        '/Users/someone/Documents/mydia_fetch_log',
        OSError('Resource temporarily unavailable', 35),
      );

      expect(isLockContentionError(error), isTrue);
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
}
