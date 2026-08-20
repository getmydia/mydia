// Service Worker standing in for LocalProxyService.
//
// A browser cannot run an HTTP server, so this claims the same paths the
// loopback server serves on desktop and answers them from the page's p2p
// connection. It deliberately holds no p2p state: the browser terminates idle
// Service Workers, which would tear down a QUIC connection mid-playback.
//
// The Dart half is player/lib/core/p2p/media_proxy_web.dart.

// Scope-relative, not the literal '/p2p/': the app is served from the origin
// root on web.mydia.dev but from '/player/' when an instance hosts it, and the
// worker's scope is whichever of those it was registered under. Deriving the
// prefix keeps this file working in both, and matches the base URL the Dart
// side builds from the same scope.
//
// This file must stay beside index.html, NOT in a p2p/ subdirectory. A worker
// controls only clients whose URL is inside its scope, and it then intercepts
// every request those clients make, whatever the request URL. Scoped to
// 'p2p/', it would control nothing, because the app page is one level up.
// Measured, not assumed: moving it produced active=true, controlling=false and
// every byte-serving test failed.
const PREFIX = new URL('p2p/', self.registration.scope).pathname;

// How long to wait for the page to answer with a response head before giving
// up on it.
//
// Without a deadline, respondWith() never settles and the fetch hangs with no
// error anywhere: no status, no console entry, nothing for a viewer or a log
// to point at. Two windows make that reachable rather than theoretical. The
// page assigns its message handler only after its worker takes control, so a
// media fetch landing in that gap has nobody to answer it; and stop() clears
// the handler while this worker keeps controlling the page, because
// unregister() does not stop a worker already in control.
//
// 60s is chosen against what the page does before it replies with a head: one
// p2p round trip to the instance, which for the first segment of a fresh
// session waits on the instance's HLS session becoming ready (its own 30s
// budget, in lib/mydia/p2p/server.ex).
//
// It has to exceed that budget, not match it. At an equal 30s the two
// deadlines race and a cold start that legitimately uses its full budget
// loses: the instance answers at the moment this worker gives up, so a
// working session returns 503. Worse, that 503 is indistinguishable from a
// genuine transport fault, which makes it the most misleading failure this
// file can produce. The headroom covers the instance's own wait plus the
// relay round trip carrying the answer back, and a browser connection never
// hole-punches, so it always pays relay latency.
//
// Nothing legitimate waits on the full 60s: the failures it catches are
// handler-is-missing states that would otherwise wait forever.
const REPLY_TIMEOUT_MS = 60_000;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin || !url.pathname.startsWith(PREFIX)) {
    return; // Not ours. Let the network have it.
  }
  event.respondWith(proxyToPage(event));
});

async function proxyToPage(event) {
  const client = await resolveClient(event);
  if (!client) {
    // The tab that owns the connection is gone. The app re-registers on load.
    return new Response('No p2p client available', { status: 503 });
  }

  const channel = new MessageChannel();
  const url = new URL(event.request.url);

  const headers = {};
  for (const [key, value] of event.request.headers.entries()) {
    headers[key] = value;
  }

  const head = new Promise((resolve, reject) => {
    let settled = false;
    const stream = new ReadableStream({
      start(controller) {
        channel.port1.onmessage = (message) => {
          const payload = message.data;
          switch (payload.type) {
            case 'head':
              settled = true;
              resolve({ status: payload.status, headers: payload.headers, stream });
              break;
            case 'chunk':
              controller.enqueue(payload.data);
              break;
            case 'end':
              controller.close();
              channel.port1.close();
              break;
            case 'error':
              if (settled) {
                controller.error(new Error(payload.message));
              } else {
                reject(new Error(payload.message));
              }
              channel.port1.close();
              break;
          }
        };
      },
      cancel() {
        channel.port1.postMessage({ type: 'cancel' });
        channel.port1.close();
      },
    });
  });

  client.postMessage(
    {
      type: 'p2p-request',
      id: crypto.randomUUID(),
      // Path only. The loopback proxy reads request.uri.path and drops the
      // query, so forwarding one here would put it inside the HLS sub-path
      // the peer is asked for, and only on web.
      path: url.pathname.slice(PREFIX.length - 1),
      headers,
    },
    [channel.port2],
  );

  // Resolves null, which no head ever is, so the race below can tell the two
  // apart without a sentinel object.
  let timer;
  const deadline = new Promise((resolve) => {
    timer = setTimeout(() => resolve(null), REPLY_TIMEOUT_MS);
  });

  try {
    const settled = await Promise.race([head, deadline]);
    if (settled === null) {
      // Same 503 the no-controlled-client path answers with, for the same
      // reason: the page that owns the p2p connection is not answering, and a
      // status the browser can surface beats a fetch that never returns.
      channel.port1.postMessage({ type: 'cancel' });
      channel.port1.close();
      return new Response('The p2p client did not answer', { status: 503 });
    }
    const { status, headers: responseHeaders, stream } = settled;
    return new Response(stream, { status, headers: responseHeaders });
  } catch (error) {
    return new Response(String(error), { status: 502 });
  } finally {
    // Only the head is on a deadline. Once it has arrived the body streams for
    // as long as it takes, which for a media file is unbounded by design.
    clearTimeout(timer);
  }
}

// Prefer the client that issued the request; fall back to any controlled
// window, because media element fetches can arrive without a client id.
async function resolveClient(event) {
  if (event.clientId) {
    const client = await self.clients.get(event.clientId);
    if (client) return client;
  }
  const windows = await self.clients.matchAll({ type: 'window' });
  return windows[0] || null;
}
