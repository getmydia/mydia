// Mydia service worker.
//
// It caches exactly one thing: the offline page, shown when a page navigation
// cannot reach the server. Static assets are not cached here because
// fingerprinted files already carry long-lived HTTP cache headers. Everything
// else, including the API, LiveView, media streams, downloads, range requests
// and the Flutter player under /player, is left to the browser untouched.
// Caching those filled the origin's storage quota with video and replayed
// authenticated API responses offline.
const CACHE_NAME = "mydia-v2";
const OFFLINE_URL = "/offline.html";

const PASSTHROUGH_PREFIXES = ["/api", "/live", "/phoenix", "/player"];
const GATEWAY_ERRORS = [502, 503, 504];

function route(request, origin) {
  if (request.method !== "GET") return "passthrough";

  const url = new URL(request.url);
  if (url.origin !== origin) return "passthrough";
  if (request.headers.get("range")) return "passthrough";
  if (PASSTHROUGH_PREFIXES.some((p) => url.pathname === p || url.pathname.startsWith(p + "/"))) {
    return "passthrough";
  }

  return request.mode === "navigate" ? "navigate" : "passthrough";
}

async function cachedOfflinePage() {
  const cache = await caches.open(CACHE_NAME);
  return cache.match(OFFLINE_URL);
}

async function networkWithOfflineFallback(request) {
  let response;
  try {
    response = await fetch(request);
  } catch (_error) {
    return (await cachedOfflinePage()) || Response.error();
  }

  if (GATEWAY_ERRORS.includes(response.status)) {
    return (await cachedOfflinePage()) || response;
  }
  return response;
}

if (typeof self !== "undefined" && typeof self.addEventListener === "function") {
  self.addEventListener("install", (event) => {
    // Swallow failures so the worker still installs when offline.html cannot be fetched (e.g. an auth proxy redirects it).
    event.waitUntil(
      caches
        .open(CACHE_NAME)
        .then((cache) => cache.add(OFFLINE_URL))
        .catch(() => {})
    );
    self.skipWaiting();
  });

  self.addEventListener("activate", (event) => {
    event.waitUntil(
      caches
        .keys()
        .then((names) => Promise.all(names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n))))
        .then(() => self.clients.claim())
    );
  });

  self.addEventListener("fetch", (event) => {
    if (route(event.request, self.location.origin) === "navigate") {
      event.respondWith(networkWithOfflineFallback(event.request));
    }
    // passthrough: no respondWith, the browser handles it.
  });
}

// Lets assets/test/unit/service_worker_route.test.mjs load `route` in Node.
// `module` does not exist in a browser worker, so this is a no-op there.
if (typeof module !== "undefined") module.exports = { route, CACHE_NAME };
