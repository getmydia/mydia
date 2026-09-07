import type { Hono } from "hono";
import type { Env } from "../env";

// The iroh relays mydia operates, in preference order. Source of truth,
// alongside metadata-relay/lib/metadata_relay/client_config.ex, which carries
// the same list and must change in the same commit. test/contract/routes.json
// includes /client-config so the cutover gate diffs the two live services.
//
// Installs read this at boot to learn which relays to use, which is what lets
// a relay be moved by deploying this Worker rather than shipping a new server
// image and player build. Changing it is a relay-worker-v* tag.
//
// Clients append iroh's own public relays underneath these, so this list
// carries only mydia's own.
export const RELAY_URLS = ["https://cae1-1.relay.mydia.dev"] as const;

// One hour at the edge, a day of serving stale while revalidating, a week of
// serving stale if the origin is failing. A relay move is a planned change, so
// an hour of staleness costs nothing, and every install calls this on every
// boot, so the cache is worth having.
const CACHE_CONTROL =
  "public, s-maxage=3600, stale-while-revalidate=86400, stale-if-error=604800";

export function registerClientConfigRoutes(app: Hono<{ Bindings: Env }>): void {
  app.get("/client-config", (c) =>
    c.json({ p2p: { relays: RELAY_URLS } }, 200, {
      "cache-control": CACHE_CONTROL,
    }),
  );
}
