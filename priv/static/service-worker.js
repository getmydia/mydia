// Mydia service worker.
//
// An allowlist: it only ever touches fingerprinted static files, a handful of
// shell files, and page navigations (for the offline page). Everything else,
// including the API, LiveView, media streams, downloads, range requests and the
// Flutter player under /player, is left to the browser untouched. Caching those
// filled the origin's storage quota with video and replayed authenticated API
// responses offline.
const CACHE_NAME = "mydia-v2";
const OFFLINE_URL = "/offline.html";

const PRECACHE = [OFFLINE_URL, "/images/logo.svg", "/favicon.ico"];

// Phoenix digests file names as `name-<32 hex>.ext`.
const DIGESTED = /-[0-9a-f]{32}\.[a-z0-9]+$/;
const PASSTHROUGH_PREFIXES = ["/api", "/live", "/phoenix", "/player"];

function route(request, origin) {
  if (request.method !== "GET") return "passthrough";

  const url = new URL(request.url);
  if (url.origin !== origin) return "passthrough";
  if (request.headers.get("range")) return "passthrough";
  if (PASSTHROUGH_PREFIXES.some((p) => url.pathname === p || url.pathname.startsWith(p + "/"))) {
    return "passthrough";
  }

  if (request.mode === "navigate") return "navigate";

  if (DIGESTED.test(url.pathname) || PRECACHE.includes(url.pathname) || url.pathname.startsWith("/images/icons/")) {
    return "static";
  }

  return "passthrough";
}

async function cacheFirst(request) {
  const cache = await caches.open(CACHE_NAME);
  const cached = await cache.match(request);
  if (cached) return cached;

  const response = await fetch(request);
  if (response.status === 200) await cache.put(request, response.clone());
  return response;
}

async function networkWithOfflineFallback(request) {
  try {
    return await fetch(request);
  } catch (_error) {
    const cache = await caches.open(CACHE_NAME);
    return (await cache.match(OFFLINE_URL)) || Response.error();
  }
}

if (typeof self !== "undefined" && typeof self.addEventListener === "function") {
  self.addEventListener("install", (event) => {
    event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(PRECACHE)));
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
    switch (route(event.request, self.location.origin)) {
      case "static":
        event.respondWith(cacheFirst(event.request));
        break;
      case "navigate":
        event.respondWith(networkWithOfflineFallback(event.request));
        break;
      default:
        // passthrough: no respondWith, the browser handles it.
        break;
    }
  });
}

// Lets assets/test/unit/service_worker_route.test.mjs load `route` in Node.
// `module` does not exist in a browser worker, so this is a no-op there.
if (typeof module !== "undefined") module.exports = { route, CACHE_NAME };
