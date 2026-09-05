import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/backends/flatpak_update_backend.dart';
import 'package:player/core/update/flatpak_portal.dart';
import 'package:player/core/update/update_backend.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/domain/models/available_update.dart';

/// `build()` calls the real `PackageInfo.fromPlatform()`, which is a
/// MethodChannel call. `flutter test` never runs the generated dart plugin
/// registrant for plain (non-widget) tests, so without this mock the call
/// throws MissingPluginException, is swallowed by `_init`'s catch, and every
/// test below would see a notifier that never got as far as creating a
/// backend.
const _packageInfoChannel =
    MethodChannel('dev.fluttercommunity.plus/package_info');

class _FakeBackend implements UpdateBackend {
  _FakeBackend({this.outcome = const AlreadyUpToDate()});

  final UpdateOutcome outcome;
  final controller = StreamController<AvailableUpdate?>.broadcast();
  int refreshes = 0;
  bool disposed = false;

  @override
  Future<void> start() async {}

  @override
  Stream<AvailableUpdate?> get availability => controller.stream;

  @override
  ManualCheckBehaviour get manualCheck =>
      ManualCheckBehaviour.checksAndInstalls;

  @override
  bool get canUpdateInPlace => true;

  @override
  Future<void> refresh({bool force = false}) async => refreshes++;

  @override
  Future<UpdateOutcome> requestUpdate({
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.5);
    return outcome;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await controller.close();
  }
}

/// A portal that monitors happily but cannot spawn, which is the shape of a
/// restart failing after a successful install.
class _RestartFailingPortal implements FlatpakPortal {
  @override
  Stream<FlatpakCommits> get updatesAvailable => const Stream.empty();

  @override
  Future<void> startMonitoring() async {}

  @override
  Stream<FlatpakProgress> update() => const Stream.empty();

  @override
  Future<void> restartIntoLatest() async => throw Exception('spawn refused');

  @override
  Future<void> close() async {}
}

ProviderContainer _container(_FakeBackend backend) {
  final container = ProviderContainer(
    overrides: [
      updateBackendFactoryProvider.overrideWithValue(
        ({required String currentVersion}) => backend,
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_packageInfoChannel, (call) async {
      if (call.method == 'getAll') {
        return {
          'appName': 'Mydia Player',
          'packageName': 'dev.mydia.player',
          'version': '0.15.0',
          'buildNumber': '1',
        };
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_packageInfoChannel, null);
  });

  test('an update published by the backend reaches the state', () async {
    final backend = _FakeBackend();
    final container = _container(backend);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    backend.controller.add(const FlatpakRemoteUpdate(
      releaseNotesUrl: 'https://example.invalid/releases',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(container.read(updateProvider).availableUpdate,
        isA<FlatpakRemoteUpdate>());
  });

  test('the manual check behaviour comes from the backend', () async {
    final backend = _FakeBackend();
    final container = _container(backend);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(updateProvider).manualCheck,
        ManualCheckBehaviour.checksAndInstalls);
  });

  test('an up-to-date result leaves a notice and no update', () async {
    final backend = _FakeBackend();
    final container = _container(backend);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(updateProvider.notifier).requestUpdate();

    final state = container.read(updateProvider);
    expect(state.notice, "You're up to date");
    expect(state.availableUpdate, isNull);
    expect(state.isApplying, isFalse);
  });

  test('an installed result asks for a restart', () async {
    final backend = _FakeBackend(
      outcome: const UpdateInstalled(restartRequired: true),
    );
    final container = _container(backend);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(updateProvider.notifier).requestUpdate();

    expect(container.read(updateProvider).restartRequired, isTrue);
  });

  test('an unsupported result surfaces its reason as an error', () async {
    final backend = _FakeBackend(
      outcome: const UpdateUnsupported('This update needs new permissions.'),
    );
    final container = _container(backend);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(updateProvider.notifier).requestUpdate();

    expect(container.read(updateProvider).error, contains('permissions'));
  });

  test('a failure surfaces its message', () async {
    final backend =
        _FakeBackend(outcome: const UpdateFailed('connection reset'));
    final container = _container(backend);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(updateProvider.notifier).requestUpdate();

    expect(container.read(updateProvider).error, contains('connection reset'));
  });

  test('a restart that fails still says the update is installed', () async {
    // The new build is deployed either way, so a failed Spawn must not read
    // as a failed update.
    final portal = _RestartFailingPortal();
    final backend = FlatpakUpdateBackend(
      portal: portal,
      releaseNotesUrl: 'https://example.invalid/releases',
    );
    final container = ProviderContainer(
      overrides: [
        updateBackendFactoryProvider.overrideWithValue(
          ({required String currentVersion}) => backend,
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(updateProvider.notifier).restart();

    final state = container.read(updateProvider);
    expect(state.notice, 'Update installed. Reopen Mydia to finish.');
    expect(state.error, isNull);
  });

  test('checkForUpdate on a check-and-install backend installs', () async {
    final backend = _FakeBackend(
      outcome: const UpdateInstalled(restartRequired: true),
    );
    final container = _container(backend);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(updateProvider.notifier).checkForUpdate();

    expect(backend.refreshes, 0);
    expect(container.read(updateProvider).restartRequired, isTrue);
  });
}
