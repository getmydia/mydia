import 'dart:async';
import 'dart:io' show exit;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/backends/flatpak_update_backend.dart';
import 'package:player/core/update/flatpak_portal.dart';
import 'package:player/core/update/update_backend.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/core/update/update_track.dart';
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
  _FakeBackend({
    this.outcome = const AlreadyUpToDate(),
    this.trackSwitchOutcome = const TrackSwitchApplied(),
    UpdateTrack currentTrack = UpdateTrack.stable,
  }) : _currentTrack = currentTrack;

  final UpdateOutcome outcome;

  /// Mutable so a test can change what the next `selectTrack` call returns,
  /// proving trackUrl is decided fresh on every switch rather than sticking
  /// from an earlier one.
  TrackSwitchOutcome trackSwitchOutcome;
  final controller = StreamController<AvailableUpdate?>.broadcast();
  int refreshes = 0;
  bool disposed = false;
  UpdateTrack _currentTrack;

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
  Set<UpdateTrack> get availableTracks =>
      const {UpdateTrack.stable, UpdateTrack.beta, UpdateTrack.dev};

  @override
  UpdateTrack get currentTrack => _currentTrack;

  @override
  Future<TrackSwitchOutcome> selectTrack(UpdateTrack track) async {
    // A real backend that applies the switch also starts reporting the new
    // track, which is what UpdateNotifier.selectTrack reads back afterward.
    if (trackSwitchOutcome is TrackSwitchApplied) _currentTrack = track;
    return trackSwitchOutcome;
  }

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

/// A portal whose Spawn succeeds, which is the shape of a restart that
/// actually needs this process to end.
class _RestartSucceedingPortal implements FlatpakPortal {
  @override
  Stream<FlatpakCommits> get updatesAvailable => const Stream.empty();

  @override
  Future<void> startMonitoring() async {}

  @override
  Stream<FlatpakProgress> update() => const Stream.empty();

  @override
  Future<void> restartIntoLatest() async {}

  @override
  Future<void> close() async {}
}

ProviderContainer _container(_FakeBackend backend) {
  final container = ProviderContainer(
    overrides: [
      updateBackendFactoryProvider.overrideWithValue(
        ({required String currentVersion}) async => backend,
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
    debugExitProcess = exit;
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

  test(
      'a deferred result clears the pending update and says where it went, '
      'instead of leaving the same Update Now row', () async {
    final backend = _FakeBackend(outcome: const UpdateDeferred());
    final container = _container(backend);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    // Established first, so clearing it below is observable rather than a
    // no-op on a field that was already null.
    backend.controller.add(const FlatpakRemoteUpdate(
      releaseNotesUrl: 'https://example.invalid/releases',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(updateProvider).availableUpdate, isNotNull);

    await container.read(updateProvider.notifier).requestUpdate();

    final state = container.read(updateProvider);
    expect(state.availableUpdate, isNull);
    expect(state.isApplying, isFalse);
    expect(state.notice, isNotNull);
    // The card falls back to `update != null` for its "Update Now" row, so a
    // notice that does not clear the update would draw that row right back
    // and invite tapping it a second time while the first hand-off is still
    // waiting on the user.
    expect(state.error, isNull);
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
    final exitCalls = <int>[];
    debugExitProcess = exitCalls.add;

    final portal = _RestartFailingPortal();
    final backend = FlatpakUpdateBackend(
      portal: portal,
      releaseNotesUrl: 'https://example.invalid/releases',
    );
    final container = ProviderContainer(
      overrides: [
        updateBackendFactoryProvider.overrideWithValue(
          ({required String currentVersion}) async => backend,
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
    // A failed Spawn leaves this process on the stale build. Exiting it
    // anyway would strand the user with no running Mydia Player at all.
    expect(exitCalls, isEmpty);
  });

  test('a successful restart exits this process', () async {
    // Spawn starts a new process rather than replacing this one, so a
    // successful restart has to end this process itself or the user is left
    // running two copies of Mydia Player, one on the stale build.
    final exitCalls = <int>[];
    debugExitProcess = exitCalls.add;

    final portal = _RestartSucceedingPortal();
    final backend = FlatpakUpdateBackend(
      portal: portal,
      releaseNotesUrl: 'https://example.invalid/releases',
    );
    final container = ProviderContainer(
      overrides: [
        updateBackendFactoryProvider.overrideWithValue(
          ({required String currentVersion}) async => backend,
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(updateProvider.notifier).restart();

    expect(exitCalls, [0]);
    final state = container.read(updateProvider);
    expect(state.notice, isNull);
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

  test('the backend\'s tracks and current track reach the state', () async {
    final backend = _FakeBackend(currentTrack: UpdateTrack.beta);
    final container = _container(backend);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    final state = container.read(updateProvider);
    expect(state.availableTracks, backend.availableTracks);
    expect(state.currentTrack, UpdateTrack.beta);
  });

  test('an applied track switch updates the current track', () async {
    final backend = _FakeBackend(currentTrack: UpdateTrack.stable);
    final container = _container(backend);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(updateProvider.notifier).selectTrack(UpdateTrack.dev);

    final state = container.read(updateProvider);
    expect(state.currentTrack, UpdateTrack.dev);
    expect(state.trackNotice, isNull);
  });

  test('a deferred track switch reports its instructions without switching',
      () async {
    final backend = _FakeBackend(
      trackSwitchOutcome: const TrackSwitchDeferred(
        instructions: 'flatpak install mydia-beta dev.mydia.player//beta',
        url: 'https://example.invalid/install',
      ),
    );
    final container = _container(backend);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(updateProvider.notifier).selectTrack(UpdateTrack.beta);

    final state = container.read(updateProvider);
    expect(state.trackNotice, contains('flatpak install'));
    expect(state.trackUrl, 'https://example.invalid/install');
    // The instructions live in trackNotice, not notice: the update card reads
    // notice, and a deferred track switch has nothing to do with it.
    expect(state.notice, isNull);
    expect(state.currentTrack, UpdateTrack.stable);
  });

  test('a deferred track switch with no url leaves trackUrl null', () async {
    final backend = _FakeBackend(
      trackSwitchOutcome: const TrackSwitchDeferred(
        instructions: 'Ask an administrator to change your update channel.',
      ),
    );
    final container = _container(backend);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(updateProvider.notifier).selectTrack(UpdateTrack.beta);

    final state = container.read(updateProvider);
    expect(state.trackNotice, isNotNull);
    expect(state.trackUrl, isNull);
  });

  test('a later deferred switch with no url clears a previous one', () async {
    final backend = _FakeBackend(
      trackSwitchOutcome: const TrackSwitchDeferred(
        instructions: 'flatpak install mydia-beta dev.mydia.player//beta',
        url: 'https://example.invalid/install',
      ),
    );
    final container = _container(backend);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(updateProvider.notifier).selectTrack(UpdateTrack.beta);
    expect(container.read(updateProvider).trackUrl, isNotNull);

    backend.trackSwitchOutcome = const TrackSwitchDeferred(
      instructions: 'flatpak install mydia dev.mydia.player//stable',
    );
    await container
        .read(updateProvider.notifier)
        .selectTrack(UpdateTrack.stable);

    // copyWith's `??` would otherwise let the stale url survive a fresh
    // deferred switch that did not repeat it.
    expect(container.read(updateProvider).trackUrl, isNull);
  });

  test('an applied track switch clears a previous deferred url', () async {
    final backend = _FakeBackend(
      trackSwitchOutcome: const TrackSwitchDeferred(
        instructions: 'flatpak install mydia-beta dev.mydia.player//beta',
        url: 'https://example.invalid/install',
      ),
    );
    final container = _container(backend);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(updateProvider.notifier).selectTrack(UpdateTrack.beta);
    expect(container.read(updateProvider).trackUrl, isNotNull);

    backend.trackSwitchOutcome = const TrackSwitchApplied();
    await container.read(updateProvider.notifier).selectTrack(UpdateTrack.dev);

    expect(container.read(updateProvider).trackUrl, isNull);
  });

  test('an unsupported track switch surfaces its reason as an error', () async {
    final backend = _FakeBackend(
      trackSwitchOutcome:
          const TrackSwitchUnsupported('Dev builds are not published yet.'),
    );
    final container = _container(backend);
    container.read(updateProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(updateProvider.notifier).selectTrack(UpdateTrack.dev);

    final state = container.read(updateProvider);
    expect(state.error, contains('not published'));
    expect(state.currentTrack, UpdateTrack.stable);
  });
}
