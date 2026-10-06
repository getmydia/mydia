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
    mediaSourceProvider(_idA).overrideWithValue(a),
    mediaSourceProvider(_idB).overrideWithValue(b),
  ]);
  addTearDown(container.dispose);
  return (container: container, a: a, b: b);
}

void main() {
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

  test('the old source is detached after a switch', () {
    final t = _setup();
    var rebuilds = 0;
    t.container.listen(currentSourceStatusProvider, (_, __) => rebuilds++,
        fireImmediately: true);
    t.container.read(selectedSourceIdProvider.notifier).select(_idB);
    t.container.read(currentSourceStatusProvider);
    final before = rebuilds;

    t.a.setStatus(SourceConnectionStatus.unreachable);
    t.container.read(currentSourceStatusProvider);

    expect(rebuilds, before);
    expect(t.container.read(currentSourceStatusProvider),
        SourceConnectionStatus.local);
  });
}
