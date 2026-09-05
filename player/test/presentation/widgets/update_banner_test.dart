import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/compatibility/compatibility_provider.dart';
import 'package:player/core/compatibility/compatibility_verdict.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/update/update_dismissal_provider.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/domain/models/app_update.dart';
import 'package:player/presentation/widgets/update_banner.dart';

class _FakeUpdateNotifier extends UpdateNotifier {
  _FakeUpdateNotifier(this._state);
  final UpdateState _state;

  @override
  UpdateState build() => _state;

  @override
  Future<void> applyUpdate() async {}
}

class _FakeDismissalNotifier extends UpdateDismissalNotifier {
  _FakeDismissalNotifier(this._dismissed);
  final Set<String> _dismissed;
  final dismissedCalls = <String>[];

  @override
  Future<Set<String>> build() async => _dismissed;

  @override
  Future<void> dismiss(String version) async => dismissedCalls.add(version);
}

class _FakeCompatibilityNotifier extends CompatibilityNotifier {
  _FakeCompatibilityNotifier(this._state);
  final CompatibilityState _state;

  @override
  Future<CompatibilityState> build() async => _state;
}

class _FakeAuthNotifier extends AuthStateNotifier {
  _FakeAuthNotifier(this._status);
  final AuthStatus _status;

  @override
  AsyncValue<AuthStatus> build() => AsyncValue.data(_status);
}

AppUpdate _update({String version = '0.15.0'}) => AppUpdate(
      version: version,
      downloadUrl: 'https://example.invalid/player-linux-v$version.tar.gz',
      releaseNotesUrl: 'https://example.invalid/releases/$version',
      releaseTitle: 'Faster library scans',
      publishedAt: DateTime.utc(2026, 8, 1),
    );

const _compatible = CompatibilityState(
  verdict: CompatibilityVerdict.compatible,
  playerVersion: '0.14.2',
  serverVersion: '0.14.2',
);

Future<_FakeDismissalNotifier> _pump(
  WidgetTester tester, {
  required UpdateState state,
  Set<String> dismissed = const <String>{},
  CompatibilityState compatibility = _compatible,
  AuthStatus auth = AuthStatus.authenticated,
  bool supported = true,
  List<Uri>? launched,
}) async {
  final dismissal = _FakeDismissalNotifier(dismissed);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        updateProvider.overrideWith(() => _FakeUpdateNotifier(state)),
        updateDismissalProvider.overrideWith(() => dismissal),
        compatibilityProvider
            .overrideWith(() => _FakeCompatibilityNotifier(compatibility)),
        authStateProvider.overrideWith(() => _FakeAuthNotifier(auth)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: UpdateBanner(
            supportedOverride: supported,
            launcher: (uri) async => launched?.add(uri),
          ),
        ),
      ),
    ),
  );
  // The dismissal and compatibility notifiers build asynchronously, so the
  // first frame has neither. `pumpAndSettle` cannot be used here: a
  // BannerButton spinner (isApplying: true) renders an indeterminate
  // CircularProgressIndicator, whose AnimationController.repeat() never stops
  // scheduling frames, so pumpAndSettle would spin until it times out. Two
  // plain pumps are enough to flush both providers' already-resolved futures.
  await tester.pump();
  await tester.pump();
  return dismissal;
}

void main() {
  group('shouldShowUpdateBanner', () {
    bool show({
      bool supported = true,
      bool isMacOS = false,
      String? availableVersion = '0.15.0',
      Set<String>? dismissedVersions = const <String>{},
      bool compatibilityBannerShowing = false,
      bool isOffline = false,
    }) =>
        shouldShowUpdateBanner(
          supported: supported,
          isMacOS: isMacOS,
          availableVersion: availableVersion,
          dismissedVersions: dismissedVersions,
          compatibilityBannerShowing: compatibilityBannerShowing,
          isOffline: isOffline,
        );

    test('an available update on a supported desktop shows', () {
      expect(show(), isTrue);
    });

    test('a platform without an in-app updater shows nothing', () {
      expect(show(supported: false), isFalse);
    });

    test('macOS shows nothing, because Sparkle notifies natively', () {
      expect(show(isMacOS: true), isFalse);
    });

    test('no available update shows nothing', () {
      expect(show(availableVersion: null), isFalse);
    });

    test('a dismissed version shows nothing', () {
      expect(show(dismissedVersions: {'0.15.0'}), isFalse);
    });

    test('a dismissal of another version does not suppress this one', () {
      expect(show(dismissedVersions: {'0.14.0'}), isTrue);
    });

    test('unloaded dismissals show nothing yet', () {
      // Defaulting to "nothing dismissed" would paint the banner on the first
      // frame and yank it away once the box resolved.
      expect(show(dismissedVersions: null), isFalse);
    });

    test('a compatibility banner already saying this wins', () {
      expect(show(compatibilityBannerShowing: true), isFalse);
    });

    test('offline shows nothing, since nothing can be downloaded', () {
      expect(show(isOffline: true), isFalse);
    });
  });

  group('UpdateBanner', () {
    testWidgets('announces an available update', (tester) async {
      await _pump(
        tester,
        state:
            UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
      );

      expect(find.textContaining('0.15.0'), findsOneWidget);
      expect(find.text('Update'), findsOneWidget);
      expect(find.text('Notes'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('renders nothing with no update available', (tester) async {
      await _pump(tester, state: const UpdateState(currentVersion: '0.14.2'));

      expect(find.byType(Text), findsNothing);
      expect(find.byType(Container), findsNothing);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('renders nothing for a dismissed version', (tester) async {
      await _pump(
        tester,
        state:
            UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
        dismissed: {'0.15.0'},
      );

      expect(find.byType(Text), findsNothing);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets(
        'renders nothing while a player-behind compatibility banner shows',
        (tester) async {
      await _pump(
        tester,
        state:
            UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
        compatibility: const CompatibilityState(
          verdict: CompatibilityVerdict.playerUpdateRequired,
          playerVersion: '0.14.2',
          serverVersion: '0.15.0',
          requiredVersion: '0.15.0',
        ),
      );

      expect(find.byType(Text), findsNothing);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('shows when a player-behind nudge was already dismissed',
        (tester) async {
      // CompatibilityState.showBanner folds in its own dismissal box. Gating
      // on the verdict alone would leave this user with no banner at all.
      await _pump(
        tester,
        state:
            UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
        compatibility: const CompatibilityState(
          verdict: CompatibilityVerdict.playerUpdateRecommended,
          playerVersion: '0.14.2',
          serverVersion: '0.15.0',
          requiredVersion: '0.15.0',
          dismissed: true,
        ),
      );

      expect(find.textContaining('0.15.0'), findsOneWidget);
    });

    testWidgets('renders nothing in offline mode', (tester) async {
      await _pump(
        tester,
        state:
            UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
        auth: AuthStatus.offlineMode,
      );

      expect(find.byType(Text), findsNothing);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('renders nothing on a platform that cannot self-update',
        (tester) async {
      await _pump(
        tester,
        state:
            UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
        supported: false,
      );

      expect(find.byType(Text), findsNothing);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('dismissing records the version', (tester) async {
      final dismissal = await _pump(
        tester,
        state:
            UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
      );

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(dismissal.dismissedCalls, ['0.15.0']);
    });

    testWidgets('Notes opens the release page', (tester) async {
      final launched = <Uri>[];
      await _pump(
        tester,
        state:
            UpdateState(currentVersion: '0.14.2', availableUpdate: _update()),
        launched: launched,
      );

      await tester.tap(find.text('Notes'));
      await tester.pumpAndSettle();

      expect(launched, [Uri.parse('https://example.invalid/releases/0.15.0')]);
    });

    testWidgets('a failed apply offers a retry with the error', (tester) async {
      await _pump(
        tester,
        state: UpdateState(
          currentVersion: '0.14.2',
          availableUpdate: _update(),
          error: 'Update failed: connection closed',
        ),
      );

      expect(find.textContaining('connection closed'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Update'), findsNothing);
    });

    testWidgets('while applying the action spins instead of inviting a retap',
        (tester) async {
      await _pump(
        tester,
        state: UpdateState(
          currentVersion: '0.14.2',
          availableUpdate: _update(),
          isApplying: true,
          downloadProgress: 0.4,
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Update'), findsNothing);
    });
  });
}
