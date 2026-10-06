import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/current_source_status.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';

import '../../presentation/screens/sources/fake_media_source.dart';

class _Selected extends SelectedSourceNotifier {
  _Selected(this.initial);
  final SourceId? initial;

  @override
  SourceId? build() => initial;

  @override
  void select(SourceId id) => state = id;
}

const _idA = SourceId('acc1:owner:aa11');
const _idB = SourceId('acc2:owner:bb22');

({ProviderContainer container, FakeMediaSource a, FakeMediaSource b}) _setup(
    {SourceId? selected = _idA}) {
  final a = FakeMediaSource();
  final b = FakeMediaSource();
  final container = ProviderContainer(overrides: [
    selectedSourceIdProvider.overrideWith(() => _Selected(selected)),
    activeSourceIdProvider
        .overrideWith((ref) => ref.watch(selectedSourceIdProvider)),
    mediaSourceProvider(_idA).overrideWithValue(a),
    mediaSourceProvider(_idB).overrideWithValue(b),
  ]);
  addTearDown(container.dispose);
  return (container: container, a: a, b: b);
}

void main() {
  test('statusSourceIdFor: /s/<id> wins, else active', () {
    expect(statusSourceIdFor('/s/acc2%3Aowner%3Abb22/library/1', active: _idA),
        _idB);
    expect(statusSourceIdFor('/', active: _idB), _idB);
    expect(statusSourceIdFor('/movies', active: _idB), _idB);
    expect(statusSourceIdFor('/'), isNull);
  });

  test('follows the selected source: connecting, remote, unreachable', () {
    final t = _setup();
    t.a.setStatus(SourceConnectionStatus.connecting);
    final seen = <SourceConnectionStatus?>[];
    t.container.listen(currentSourceStatusProvider, (_, next) => seen.add(next),
        fireImmediately: true);

    t.a.setStatus(SourceConnectionStatus.remote);
    t.container.read(currentSourceStatusProvider);
    t.a.setStatus(SourceConnectionStatus.unreachable);
    t.container.read(currentSourceStatusProvider);

    expect(seen, [
      SourceConnectionStatus.connecting,
      SourceConnectionStatus.remote,
      SourceConnectionStatus.unreachable,
    ]);
    expect(isOffline(seen.last), isTrue);
    expect(isOffline(SourceConnectionStatus.remote), isFalse);
    expect(isOffline(null), isFalse);
  });

  test('is null with no selection', () {
    final t = _setup(selected: null);
    expect(t.container.read(currentSourceStatusProvider), isNull);
  });

  test('switching the selection switches the status', () {
    final t = _setup();
    t.b.setStatus(SourceConnectionStatus.unreachable);
    expect(t.container.read(currentSourceStatusProvider),
        SourceConnectionStatus.local);

    t.container.read(selectedSourceIdProvider.notifier).select(_idB);
    expect(t.container.read(currentSourceStatusProvider),
        SourceConnectionStatus.unreachable);
  });

  test('the old source is detached after a switch', () async {
    final a = _Probed();
    final b = _Probed();
    final container = ProviderContainer(overrides: [
      selectedSourceIdProvider.overrideWith(() => _Selected(_idA)),
      activeSourceIdProvider
          .overrideWith((ref) => ref.watch(selectedSourceIdProvider)),
      mediaSourceProvider(_idA).overrideWithValue(a),
      mediaSourceProvider(_idB).overrideWithValue(b),
    ]);
    addTearDown(container.dispose);
    container.listen(currentSourceStatusProvider, (_, __) {},
        fireImmediately: true);
    expect(a.notifier.hasListening, isTrue);
    expect(b.notifier.hasListening, isFalse);

    container.read(selectedSourceIdProvider.notifier).select(_idB);
    container.read(currentSourceStatusProvider);
    await container.pump();

    expect(a.notifier.hasListening, isFalse);
    expect(b.notifier.hasListening, isTrue);
  });
}

class _ProbedNotifier extends ValueNotifier<SourceConnectionStatus> {
  _ProbedNotifier() : super(SourceConnectionStatus.local);

  bool get hasListening => hasListeners;
}

class _Probed extends FakeMediaSource {
  final notifier = _ProbedNotifier();

  @override
  SourceConnectionStatus get connection => notifier.value;

  @override
  ValueListenable<SourceConnectionStatus> get statusListenable => notifier;
}
