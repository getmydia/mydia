// Runs only under `flutter test --platform chrome`: there is no
// navigator.serviceWorker in the VM test runner, and this file's imports are
// browser-only. A VM run skips it rather than failing it.
//
// The `sw.js` beside this file is a symlink to `player/web/sw.js`, the file
// the web build ships. It has to be here because the browser test server only
// serves `player/test/`, and because a worker can only claim its own directory
// as scope: registering the shipped path from here would produce a worker that
// never sees this page's requests. A symlink rather than a copy so the file
// under test cannot drift from the file that ships.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/media_proxy_web.dart';

import 'media_proxy_conformance.dart';
import 'test_p2p_service.dart';

void main() {
  // The same suite the loopback proxy runs, against a real Service Worker in
  // a real browser: registered, activated, controlling the page, intercepting
  // the media paths and streaming a reply back from this page's fake peer.
  mediaProxyConformanceTests(
    'ServiceWorkerMediaProxy',
    ServiceWorkerMediaProxy.new,
  );

  // A browser serves one instance at its root, under whatever name it has.
  test(
      're-points to a second target, and tears down only when both holders '
      'release', () async {
    final proxy = ServiceWorkerMediaProxy(TestP2pService());
    final first = Object();
    final second = Object();
    await proxy.start(owner: first, targetPeer: 'peer', target: 'macct');
    addTearDown(proxy.shutdown);

    expect(proxy.targetBaseUrl('macct'), proxy.baseUrl);

    // The incoming route starts before the outgoing one is disposed.
    await proxy.start(owner: second, targetPeer: 'peer2', target: 'other');
    expect(proxy.isRunning, isTrue);

    // The old holder releases its lease for the old target.
    await proxy.stop(first, target: 'macct');
    expect(proxy.isRunning, isTrue);

    await proxy.stop(second, target: 'other');
    expect(proxy.isRunning, isFalse);
  });
}
