import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/app_shell.dart';

void main() {
  test('offline mode still reaches downloads and third-party sources', () {
    expect(offlineRouteAllowed('/downloads'), isTrue);
    expect(offlineRouteAllowed('/s/acc1:owner:aa11'), isTrue);
    expect(offlineRouteAllowed('/s/acc1:owner:aa11/library/movies'), isTrue);
    expect(offlineRouteAllowed('/sources/manage'), isTrue);
  });

  test('offline mode still blocks Mydia library routes', () {
    expect(offlineRouteAllowed('/movies'), isFalse);
    expect(offlineRouteAllowed('/'), isFalse);
    expect(offlineRouteAllowed('/settings'), isFalse);
  });
}
