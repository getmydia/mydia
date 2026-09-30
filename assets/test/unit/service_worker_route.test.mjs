import assert from "node:assert/strict";
import { createRequire } from "node:module";
import test from "node:test";

const require = createRequire(import.meta.url);
const { route, CACHE_NAME } = require("../../../priv/static/service-worker.js");

const ORIGIN = "https://mydia.test";

function req(path, { method = "GET", mode = "cors", headers = {}, origin = ORIGIN } = {}) {
  const lower = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  return {
    method,
    mode,
    url: new URL(path, origin).toString(),
    headers: { get: (name) => lower[name.toLowerCase()] ?? null },
  };
}

test("cache name is bumped so old caches are purged", () => {
  assert.equal(CACHE_NAME, "mydia-v2");
});

test("digested assets are static", () => {
  assert.equal(route(req("/assets/js/app-0123456789abcdef0123456789abcdef.js?vsn=d"), ORIGIN), "static");
  assert.equal(route(req("/assets/css/app-0123456789abcdef0123456789abcdef.css"), ORIGIN), "static");
});

test("undigested assets pass through so dev never serves stale code", () => {
  assert.equal(route(req("/assets/js/app.js"), ORIGIN), "passthrough");
});

test("precached shell files are static", () => {
  for (const path of ["/offline.html", "/images/logo.svg", "/images/icons/apple-touch-icon.png", "/favicon.ico"]) {
    assert.equal(route(req(path), ORIGIN), "static", path);
  }
});

test("navigations are navigate", () => {
  assert.equal(route(req("/movies", { mode: "navigate" }), ORIGIN), "navigate");
});

test("api, live, player, streams and downloads pass through", () => {
  for (const path of ["/api/v1/media/1", "/api/graphql", "/live/websocket", "/phoenix/live_reload", "/player/main.dart.js"]) {
    assert.equal(route(req(path), ORIGIN), "passthrough", path);
  }
});

test("range requests pass through even for static paths", () => {
  assert.equal(route(req("/images/logo.svg", { headers: { Range: "bytes=0-10" } }), ORIGIN), "passthrough");
});

test("non-GET passes through", () => {
  assert.equal(route(req("/movies", { method: "POST", mode: "navigate" }), ORIGIN), "passthrough");
});

test("cross-origin passes through", () => {
  assert.equal(route(req("/images/logo.svg", { origin: "https://cdn.other" }), ORIGIN), "passthrough");
});

test("navigations into /player pass through to the player's own worker", () => {
  assert.equal(route(req("/player/", { mode: "navigate" }), ORIGIN), "passthrough");
});
