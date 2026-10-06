import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/app.dart';
import 'package:player/core/auth/auth_storage.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_store.dart';

/// Where a mounted [MyApp] came to rest.
enum AppLanding {
  /// The Mydia sign-in screen ("Connect to Server") is showing.
  login,

  /// A Mydia account is already stored, so the app went past sign-in.
  signedIn,
}

/// Whether a Mydia account is stored, read from the mounted app's container.
///
/// False while the stored sources are still loading, so a false answer only
/// means "fresh install" once the add-server screen has rendered.
bool hasMydiaAccount(WidgetTester tester) {
  final finder = find.byType(MyApp);
  if (finder.evaluate().isEmpty) return false;
  final container =
      ProviderScope.containerOf(tester.element(finder.first), listen: false);
  return container.read(hasMydiaProvider);
}

/// Pumps until the app reaches the sign-in screen or turns out to be signed in.
///
/// A fresh install lands on the add-server screen, not on sign-in, so when
/// that shows this taps the Mydia tile to reach the same login screen. Uses
/// `pump()` rather than `pumpAndSettle()` because the loading screen has an
/// infinite spinner animation.
///
/// Throws when neither outcome is reached within [maxSeconds].
Future<AppLanding> waitForLoginOrSignedIn(
  WidgetTester tester, {
  int maxSeconds = 30,
  String tag = '[Test]',
}) async {
  var tappedMydia = false;
  for (var i = 0; i < maxSeconds; i++) {
    await tester.pump(const Duration(seconds: 1));
    if (find.text('Connect to Server').evaluate().isNotEmpty) {
      debugPrint('$tag Login screen found after $i seconds');
      await tester.pump(const Duration(milliseconds: 500));
      return AppLanding.login;
    }
    final mydiaTile = find.byKey(const Key('add-source-mydia'));
    if (mydiaTile.evaluate().isNotEmpty) {
      if (!tappedMydia) {
        debugPrint('$tag Add-server screen found after $i seconds');
        await tester.tap(mydiaTile);
        tappedMydia = true;
      }
      continue;
    }
    if (hasMydiaAccount(tester)) {
      debugPrint('$tag A Mydia account is already stored');
      return AppLanding.signedIn;
    }
  }
  throw StateError('Login screen not found after $maxSeconds seconds');
}

/// Like [waitForLoginOrSignedIn], for tests that need a fresh install: fails
/// if the app turns out to be signed in already.
Future<void> waitForLoginScreen(
  WidgetTester tester, {
  int maxSeconds = 30,
  String tag = '[Test]',
}) async {
  final landing =
      await waitForLoginOrSignedIn(tester, maxSeconds: maxSeconds, tag: tag);
  if (landing != AppLanding.login) {
    throw StateError('Expected a fresh install but a Mydia account is stored');
  }
}

/// Forgets every stored source and its secrets, so the next mounted app is a
/// fresh install.
///
/// Under `all_tests.dart` every file shares one isolate, and so one source
/// box and one secret store; an earlier file's pairing would otherwise leave
/// the next `MyApp` signed in.
Future<void> resetStoredSources() async {
  await getAuthStorage().deleteAll();
  final box = await Hive.openBox<String>(HiveSourceStore.boxName);
  await box.clear();
}
