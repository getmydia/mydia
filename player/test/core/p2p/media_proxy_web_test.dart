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

void main() {
  // The same suite the loopback proxy runs, against a real Service Worker in
  // a real browser: registered, activated, controlling the page, intercepting
  // the media paths and streaming a reply back from this page's fake peer.
  mediaProxyConformanceTests(
    'ServiceWorkerMediaProxy',
    ServiceWorkerMediaProxy.new,
  );
}
