import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/domain/models/cast_device.dart';

import '../../test_utils/fake_cast_backend.dart';

class _ScriptedDiscoveryBackend extends FakeCastBackend {
  _ScriptedDiscoveryBackend(this.source);

  final Stream<List<CastDevice>> source;

  @override
  Stream<List<CastDevice>> startDiscovery({
    required CastCapabilities capabilities,
    Duration timeout = const Duration(seconds: 10),
  }) =>
      source;
}

void main() {
  const phone = CastDevice(
    id: 'node-1',
    name: 'Phone',
    protocol: CastProtocolKind.mydia,
  );

  test('the merged stream completes once every source has completed', () async {
    final a = StreamController<List<CastDevice>>();
    final b = StreamController<List<CastDevice>>();
    addTearDown(a.close);
    addTearDown(b.close);

    var done = false;
    final seen = <List<CastDevice>>[];
    mergeCastDiscovery(
      [
        _ScriptedDiscoveryBackend(a.stream),
        _ScriptedDiscoveryBackend(b.stream)
      ],
      capabilities: const CastCapabilities.full(),
    ).listen(seen.add, onDone: () => done = true);

    a.add(const [phone]);
    await a.close();
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse, reason: 'one source is still live');
    expect(seen, isNotEmpty);

    await b.close();
    await Future<void>.delayed(Duration.zero);
    expect(done, isTrue);
  });
}
