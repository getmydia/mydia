import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Gives every test in the calling `main()` real `dart:io` HTTP.
///
/// Initialising the flutter_test binding replaces `HttpOverrides.global` with
/// a mock that answers every request 400, and nothing puts it back. A plain
/// `test()` file never initialises the binding, so run alone it gets real
/// sockets. CI runs the suite as one bundle, where an earlier widget test has
/// already initialised it. Call this first in `main()` of any file that talks
/// to a real local server.
void useRealHttp() {
  HttpOverrides? saved;
  setUp(() {
    saved = HttpOverrides.current;
    HttpOverrides.global = null;
  });
  tearDown(() {
    HttpOverrides.global = saved;
  });
}
