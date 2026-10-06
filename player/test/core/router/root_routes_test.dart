import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/router/root_routes.dart';
import 'package:player/core/sources/lock/source_lock_controller.dart';

void main() {
  test('server management and unlock open over the shell', () {
    expect(opensOverShell('/sources/manage'), isTrue);
    expect(opensOverShell('/sources/add'), isTrue);
    expect(opensOverShell('/sources/add/plex?account=acc1'), isTrue);
    expect(opensOverShell(unlockLocation('/sources/manage')), isTrue);
    expect(opensOverShell(unlockLocation()), isTrue);
  });

  test('shell destinations do not', () {
    expect(opensOverShell('/'), isFalse);
    expect(opensOverShell('/all'), isFalse);
    expect(opensOverShell('/s/acc1:owner:aa11'), isFalse);
    expect(opensOverShell('/settings'), isFalse);
  });
}
