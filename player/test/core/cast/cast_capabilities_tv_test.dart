// A television gets no cast capability through the real platform lookup, not
// only through the injected `forPlatform` form `cast_capabilities_test.dart`
// exercises.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';

import '../../test_utils/tv_shell_harness.dart';

void main() {
  test('forCurrentPlatform answers none on a television', () {
    expect(CastCapabilities.forCurrentPlatform().any, isFalse);
  }, skip: tvSkipReason);
}
