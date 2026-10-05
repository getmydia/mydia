import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/mydia_source.dart';
import 'package:player/core/sources/source.dart';

void main() {
  final source = MydiaSource(
    source: Source.legacyMydia(),
    auth: const AsyncData(AuthStatus.authenticated),
    jobs: () => null,
  );

  test('exposes its status as a listenable', () {
    expect(source.statusListenable.value, SourceConnectionStatus.remote);
  });

  test('browses through its own screens, not this interface', () {
    expect(source.libraries, throwsUnsupportedError);
  });
}
