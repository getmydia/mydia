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

  try {
    const { status, headers: responseHeaders, stream } = await head;
    return new Response(stream, { status, headers: responseHeaders });
  } catch (error) {
    return new Response(String(error), { status: 502 });
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
