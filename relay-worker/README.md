# Metadata Relay Worker

A Cloudflare Worker replacement for `metadata-relay/` (the Elixir/Bandit
service). It proxies TMDB, TVDB, SubDL, MusicBrainz and OpenLibrary for every
mydia install, plus pairing, crash ingest and feedback. TypeScript, Hono for
routing, no server and no tunnel — Cloudflare's edge is the whole runtime.

This is one of 17 tasks in
`docs/superpowers/plans/2026-09-05-metadata-relay-on-cloudflare-workers.md`.
Through Task 16, `relay.mydia.dev` is still served by the Elixir relay; this
Worker deploys continuously but does not yet own any production traffic. See
that plan for the full route-by-route parity work and the cutover sequence.

## What this migration changed

Things an operator who knew the Elixir relay would not expect:

- **Responses are actually cached at Cloudflare's edge now.** The Elixir
  relay sent `cache-control: max-age=0, private, must-revalidate` on every
  response, so `cf-cache-status` was `DYNAMIC` on every hit — nothing was
  ever cached at the edge despite `metadata-relay/`'s own in-process cache.
  The Worker emits real `public, s-maxage=..., stale-while-revalidate=...,
  stale-if-error=...` headers and gets genuine `HIT`s. This is a real
  latency and TMDB/TVDB-quota improvement, not a no-op port, and it's why
  the cutover verification checks `cf-cache-status` explicitly rather than
  just a 200.
- **A crash-storm occurrence count can be a floor, not an exact number.**
  D1's write budget is bounded per install-per-hour (`ingest_buckets`); once
  a bucket saturates, further occurrences in that hour are not written. The
  dashboard marks the affected error group's `count_is_floor` sticky (it
  only ever ratchets from 0 to 1, never back down, even once traffic quiets
  down) so `/admin/errors` can render "500+" instead of a wrong exact
  number. If a total looks suspiciously round or capped, that column is why.
- **The maintainer dashboards moved to `/admin/errors` and
  `/admin/feedback`.** They used to be `/errors` and `/feedback` in the
  original brief; that collided with `POST /feedback`'s public path, since
  Cloudflare Access (like Hono's router) has no HTTP-method dimension to
  separate them. Bookmarks and any saved links need updating.
- **The deploy ritual is a `git push`, not a tag.** The Elixir relay ships on
  a `metadata-relay-v*` tag, built into a Docker image, picked up by Keel's
  five-minute GHCR poll. The Worker ships on every push to `master`/`main`
  that touches `relay-worker/**`, straight to `wrangler deploy` — no tag, no
  version bump, no image, no poll delay. `git log` on `relay-worker/` is now
  effectively the release history.
- **A bulk metadata refresh can now consume rate-limit budget it never used
  to.** `src/obs/ratelimit.ts`'s proxy limiter used to check the budget
  *after* running the request, specifically so it could look at
  `x-relay-cache` and skip charging a cache hit. That shape ran the real
  upstream `fetch()` before the check could ever stop it — a final review
  found a throttled request still made its real TMDB/TVDB/SubDL/MusicBrainz/
  OpenLibrary call every time, which defeats the limiter's actual purpose
  (protecting upstream quota, worst for SubDL's shared 2000/day key). The fix
  moves the check ahead of the request, which means it now also charges cache
  hits: a "refresh every show's metadata" pass that used to be served
  entirely from cache, for free, can now spend rate-limit budget on hits it
  didn't touch before. Accepted deliberately as the stricter, fail-closed
  direction — see the comment above `rateLimitMiddleware` in that file.

## Bindings

Declared in `wrangler.jsonc` (KV, D1, rate limiters, vars) and `src/env.ts`
(the full `Env` interface, including secrets). Nothing below is optional in
production; a missing secret degrades a route to a 503/502, not a crash.

| Binding | Kind | Set via | Used for |
| --- | --- | --- | --- |
| `TMDB_API_KEY` | secret | `wrangler secret put` | TMDB proxy routes (`/tmdb/*`, `/configuration`) |
| `TVDB_API_KEY` | secret | `wrangler secret put` | TVDB proxy routes (`/tvdb/*`), including token auth |
| `SUBDL_API_KEY` | secret | `wrangler secret put` | Subtitle search/download (`/api/v1/subtitles/*`) |
| `RESEND_API_KEY` | secret | `wrangler secret put` | Feedback notification emails. Absent = notifications silently skipped, ingest still works |
| `RELAY_VERSION` | var | `wrangler.jsonc` | Reported by `/health` and `/stats` |
| `FEEDBACK_FROM` / `FEEDBACK_TO` | var | `wrangler.jsonc` | Sender/recipient for feedback notification emails |
| `CACHE_KV` | KV namespace | `wrangler kv namespace create CACHE_KV` | TVDB JWT cache and the SubDL search response cache. Everything else caches in the Cache API only |
| `DB` | D1 database | `wrangler d1 create mydia-relay` | Pairing claims, crash reports/occurrences, feedback submissions, the two rate-limit bucket tables |
| `PROXY_LIMITER` | Rate Limiting binding | `wrangler.jsonc` (`ratelimits`) | Shared per-edge-IP budget across the metadata/music/openlibrary/subtitle proxy routes |
| `PAIRING_CREATE_LIMITER` / `PAIRING_READ_LIMITER` | Rate Limiting binding | `wrangler.jsonc` (`ratelimits`) | Remote-access pairing claim creation/lookup |
| `CRASH_INGEST_LIMITER` / `FEEDBACK_INGEST_LIMITER` | Rate Limiting binding | `wrangler.jsonc` (`ratelimits`) | Atomic, D1-free burst guards in front of crash ingest's and feedback ingest's D1-backed hourly budgets — see those files' comments for why the D1 accounting alone isn't safe under concurrency |
| Cron Trigger `0 * * * *` | scheduled | `wrangler.jsonc` (`triggers.crons`) | Hourly sweep (`src/obs/sweep.ts`): evicts stale `feedback_rate_limits` rows and expired `pairing_claims` |

`ratelimits[].namespace_id` values (`1001`-`1005`) are arbitrary identifiers
for the binding, not provisioned cloud resources — there is nothing to create
for them in the dashboard, unlike `CACHE_KV` and `DB`.

**Requires wrangler >= 4.36.0.** The `ratelimits` config key was silently
dropped by older wrangler versions with no error (Task 8's finding) — the
binding would be `undefined` at runtime and every proxy route would 500. This
repo pins an exact version in `package.json`; do not loosen that pin without
re-checking this.

## Local development

```bash
npm ci
npm run dev        # wrangler dev
```

`wrangler dev` runs entirely locally (Miniflare) against the placeholder
`database_id`/KV `id` values checked into `wrangler.jsonc` — no Cloudflare
account needed for this. Provider secrets are unset locally by default, so
proxy routes 503/502 until you add a `.dev.vars` file (git-ignored) with the
four secret keys above, if you want to exercise real upstream calls.

## Testing

```bash
npm test          # vitest run — full suite, workerd runtime (Miniflare)
npm run typecheck # tsc --noEmit — covers src/ AND test/
```

Both must pass before every deploy; the CI job below runs them in that order
and stops before touching Cloudflare if either fails.

### Contract diff

```bash
npm run test:contract
```

Replays a fixed request list (`test/contract/routes.json`) against a deployed
Worker and the live Elixir relay, diffing status and body
(`test/contract/contract.test.ts`). Runs as a separate Vitest project under
plain Node (workerd's own root CA store does not trust every TLS-intercepting
proxy a given network puts in front of outbound HTTPS — see the file's own
comment for how that was diagnosed).

**Skipped by default.** `CONTRACT_WORKER_URL` is unset in ordinary
`npm test`/CI runs, so the whole suite no-ops:

```bash
CONTRACT_WORKER_URL=https://<staging>.workers.dev npm run test:contract
```

**This is not wired into CI** (see the runbook below for why and where the
real gate lives). If you ever do wire it in, you must assert the skip count is
zero — or that `CONTRACT_WORKER_URL` is set — before trusting a green run.
Vitest exits 0 for a run that is entirely `describe.skipIf`-skipped, identical
to a run where every test genuinely passed; a gate that only checks the exit
code can rubber-stamp a cutover having compared nothing.

## Deployment

**`wrangler deploy` is the release ritual.** There is no `metadata-relay-v*`
tag for this Worker and no version bump to make first — CI deploys on every
push to `master`/`main` that touches `relay-worker/**` (the `deploy-worker`
job in `.github/workflows/deploy-relay.yml`):

1. `npm ci`
2. `npm test` && `npm run typecheck`
3. `npx wrangler d1 migrations apply mydia-relay --remote` — always before the
   deploy step, so a new binding a commit adds never reaches a database that
   doesn't have its table yet
4. `npx wrangler deploy`

A test or typecheck failure stops the job before step 3, so a broken commit
on `master` cannot reach Cloudflare — but note that today nothing runs these
checks on the pull request itself (no `ci-relay-worker.yml` equivalent of
`ci-relay.yml` exists yet); the first automated signal a PR gets is this job,
after merge. See the runbook's "What Task 15 did not do" for why this wasn't
added here.

The Docker/GHCR job in the same workflow file is the **Elixir** relay's
unrelated, still-live release path (tag-triggered on `metadata-relay-v*`);
the two share the file until Task 17 deletes the Elixir side. `if:` guards on
both jobs keep a relay-worker-only commit from also invoking the Docker job
(and vice versa) — see the comment at the top of the workflow file.

### Dashboards

`GET /admin/errors` and `GET /admin/feedback` are maintainer dashboards,
replacing the Elixir's ErrorTracker page and `FeedbackLive.Index`. Both live
under a shared `/admin/*` prefix **on purpose**: it lets one Cloudflare
Access application, scoped to `/admin*`, cover every maintainer-only route by
construction, so adding a third dashboard later inherits the gate instead of
needing its own conscious Access decision. Neither dashboard shares a path
with a public endpoint — the public ingest routes (`POST /feedback`,
`POST /crashes/report`) stay exactly where every mydia install already calls
them.

**Cloudflare Access guards `/admin/*`, not code.** The Worker holds no
dashboard credentials at all — no `DASHBOARD_USERNAME`/`DASHBOARD_PASSWORD`
equivalent exists in `Env`, and none should ever be added; that pattern is
exactly what Access retires (see the runbook below for the operational trap
it closes). Setting up the Access application is a manual, one-time step —
see the runbook.

## Project structure

```
relay-worker/
├── src/
│   ├── index.ts          # Hono app, route registration, scheduled() entrypoint
│   ├── env.ts             # Env interface (bindings + secrets)
│   ├── proxy/              # tmdb/tvdb/subdl/passthrough (music, openlibrary) handlers
│   ├── cache/              # cache key derivation + get/put over Cache API + KV
│   ├── pairing/            # remote-access pairing claims
│   ├── crashes/            # crash report ingest
│   ├── feedback/           # feedback ingest (public POST) + email notification
│   ├── dashboards/         # errors + feedback maintainer dashboards, under /admin/*
│   ├── archive/             # SubDL zip extraction with size caps
│   └── obs/                # rate limiting, request logging, scheduled sweep
├── migrations/              # D1 migrations, applied by wrangler + vitest-pool-workers
├── test/                   # mirrors src/, plus test/contract (see above)
├── wrangler.jsonc
└── package.json
```

## Runbook: one-time and manual deployment steps

Everything above this line is code and CI, already working. Everything below
is **manual** — it needs Cloudflare dashboard/API access this repo's CI and
local dev environment do not have, and nobody has executed it yet. Follow it
in order; each step depends on the one before it.

### Step 0: Cloudflare account setup (before the CI job can succeed at all)

`wrangler.jsonc`'s `d1_databases[0].database_id` and `kv_namespaces[0].id` are
`"placeholder_local_dev_only"` — real for Miniflare/vitest-pool-workers, but
not a real Cloudflare resource. `wrangler deploy` and
`wrangler d1 migrations apply --remote` will fail against them. Before the
`deploy-worker` CI job can succeed even once:

1. **Create the D1 database and KV namespace** (needs a Cloudflare account
   with Workers/D1/KV enabled):
   ```bash
   cd relay-worker
   npx wrangler d1 create mydia-relay
   npx wrangler kv namespace create CACHE_KV
   ```
   Copy the `database_id` and `id` each command prints into
   `wrangler.jsonc`, replacing both `placeholder_local_dev_only` values.
   Commit that change separately from this task's CI/README commit.

2. **Set the four secrets** (once, against the real Worker):
   ```bash
   npx wrangler secret put TMDB_API_KEY
   npx wrangler secret put TVDB_API_KEY
   npx wrangler secret put SUBDL_API_KEY
   npx wrangler secret put RESEND_API_KEY
   ```

3. **Mint a Cloudflare API token for CI**, and find the account ID.
   The brief for this task assumed the token and ID in `infra/config.yaml`
   could be reused. They cannot — see "Brief vs. reality" below. Create a new
   token at <https://dash.cloudflare.com/profile/api-tokens> scoped to at
   least:
   - Account / Workers Scripts: Edit
   - Account / Workers KV Storage: Edit
   - Account / D1: Edit
   - Account / Account Settings: Read (needed to resolve the account by ID)

   Find the account ID on the Workers & Pages overview page (right sidebar).

4. **Add two repository secrets** (Settings → Secrets and variables →
   Actions), named exactly as the workflow reads them:
   - `CLOUDFLARE_API_TOKEN` — the token from step 3. This name **already
     exists** in this repository, reused by `deploy-site.yml` and
     `deploy-web-player.yml` for `wrangler pages deploy`. Check its scope
     before assuming it already works here: a Pages-only token does not
     carry Workers Scripts/D1/KV edit rights. Either broaden the existing
     token to cover both, accepting that a leak or misuse now affects Pages
     deploys too, or store the new token under a different secret name and
     point this job's two `CLOUDFLARE_API_TOKEN` references at that name
     instead. Either is fine; pick one and document which.
   - `CLOUDFLARE_ACCOUNT_ID` — does not exist yet anywhere in this
     repository's secrets or config.

Only after all of the above will the `deploy-worker` CI job's first run
succeed. Until then, every push to `master` touching `relay-worker/**` will
fail at the "Apply D1 migrations" or "Deploy" step — loudly, in CI, without
having deployed anything broken (the failure is expected and safe).

### Step 1: Cloudflare Access — hard ordering constraint

**The dashboards are currently unauthenticated.** `GET /admin/errors` and
`GET /admin/feedback` expose crash reports and user-submitted feedback,
including instance identifiers. **Nothing may be routed to a public hostname
before the Access application below exists.** This is not a recommendation to
configure Access soon after cutover — it is a precondition of cutover.
(Today, before Task 16, this Worker has no production route yet, so the
constraint is not yet live — but it must be satisfied before Task 16 adds
`relay.mydia.dev/*` routes to `wrangler.jsonc`. Task 16's own plan text now
carries this same precondition on its Step 4 — see
`docs/superpowers/plans/2026-09-05-metadata-relay-on-cloudflare-workers.md`
— so it's enforced at the point someone would otherwise miss it.)

**Why both dashboards live under `/admin/*` instead of their naive
`/errors`/`/feedback` paths:** the brief's original Step 1 asked for an
Access application covering literal `/errors` and `/feedback`. That doesn't
work. Cloudflare Access self-hosted applications match on **hostname + path
only** — there is no HTTP-method selector in Access's own policy engine
(Access policy selectors are identity/context attributes: email, country, IP
range, device posture, service token, login method; "HTTP Method" exists only
as a selector for Gateway HTTP policies, a different product inspecting
WARP-proxied client-side traffic, not inbound requests to a self-hosted
Access application — verified against Cloudflare's current documentation for
each). `POST /feedback` (public ingest, called by every install) used to
share a literal path with `GET /feedback` (the maintainer dashboard); an
Access application scoped to that path would have gated **both** methods,
since Access cannot tell them apart, breaking feedback submission fleet-wide
the moment Access was configured.

**The fix, now shipped in code:** the maintainer dashboards moved to
`/admin/errors` and `/admin/feedback` — entirely separate paths from any
public endpoint. `POST /feedback` and `POST /crashes/report` did **not**
move; they are wire contracts every deployed mydia instance already calls.
One Access application scoped to `/admin*` now cleanly covers both
dashboards, present and future, with no per-route decision and no path
collision with anything public.

**What to configure:**

1. Create one self-hosted Access application:
   - Application domain: `relay.mydia.dev`
   - Path: `/admin*` (covers `/admin/errors`, `/admin/errors/:fingerprint`,
     `/admin/errors/:fingerprint/resolve`, `/admin/errors/:fingerprint/unresolve`,
     `/admin/feedback`, `/admin/feedback/:id/state`, and
     `/admin/feedback/:id/github` — every maintainer-only route in the
     Worker, and any future one added under the same prefix)
   - Policy: Allow, Include → Emails → the maintainer address

That's it — one application, one path pattern, no exclusion list to maintain.

**Verify both halves after configuring Access:**

```bash
# GET /admin/errors: must require login
curl -sS -o /dev/null -w '%{http_code}\n' https://relay.mydia.dev/admin/errors
# expect: 302 (redirect to the Access login)

# GET /admin/feedback: must also require login
curl -sS -o /dev/null -w '%{http_code}\n' https://relay.mydia.dev/admin/feedback
# expect: 302 (redirect to the Access login)

# POST /feedback: must NOT require login — this is every install's ingest path
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://relay.mydia.dev/feedback \
  -H 'content-type: application/json' \
  -d '{"type":"idea","message":"access check"}'
# expect: 201

# GET /feedback (the OLD path): must be a plain 404, never the dashboard —
# regression-tested in test/dashboards/feedback.test.ts, but worth confirming
# against the real deploy too, since Access config is exactly the kind of
# thing that regresses independently of the code.
curl -sS -o /dev/null -w '%{http_code}\n' https://relay.mydia.dev/feedback
# expect: 404
```

If either `/admin/*` curl ever comes back 200 instead of 302, or the `POST
/feedback` curl comes back anything but 201, stop and re-check the Access
application's path scope before proceeding with cutover.

### Step 2: contract diff — not wired into CI, on purpose

`npm run test:contract` (see Testing above) is **not** part of the
`deploy-worker` CI job. Two reasons:

1. **There is nothing meaningful to diff against at Task 15's CI-job
   deploy time.** The job deploys the Worker being tested; running the
   contract diff immediately after would compare the freshly deployed Worker
   against itself moments later, which (per Task 9's finding) proves the
   harness mechanics and nothing about correctness of the change just
   shipped.
2. **An all-skipped run exits 0.** `CONTRACT_WORKER_URL` unset means the
   entire suite is `describe.skipIf`-skipped, and Vitest's exit code cannot
   distinguish that from every test passing. A CI job that ran this
   unconditionally, without separately asserting the skip count, would be a
   gate that can rubber-stamp a cutover having compared nothing — worse than
   no gate, because it looks like one.

**The real gate lives in Task 16, Step 1** — a human runs
`CONTRACT_WORKER_URL=https://<staging>.workers.dev npm run test:contract`
against a staging deploy before flipping any production route, watches the
output, and does not proceed on a single mismatch. That manual supervision is
deliberate: a person who runs the command and reads a "42 skipped" line
notices something is wrong immediately; a CI badge does not.

If this is ever automated, the job **must** fail when the skip count is
nonzero (or, simpler, assert `CONTRACT_WORKER_URL` is set before invoking
the suite at all) — never trust the bare exit code.

### Step 3: real platform CPU measurement (subtitle download path)

Task 6 shipped `src/proxy/subdl.ts`'s archive extraction (`extractSubtitle`)
with a **local-only** CPU measurement: 0.1630ms mean / 0.3049ms p99 over a
~10KB archive, measured with Node's `perf_hooks`, explicitly caveated in
`task-6-report.md` as a different engine (V8 in Node vs. workerd) and
different silicon than production. It was never validated against the real
constraint — the Workers **free plan's 10ms CPU-time-per-invocation limit** —
because that requires a deployed Worker, which did not exist when Task 6 ran.
It still doesn't, as of this task.

**Do this once the first real deploy exists** — i.e., after Step 0 above
succeeds and `deploy-worker` has pushed to the Worker's `workers.dev`
subdomain for the first time (this happens automatically; Task 16 is what
later adds `relay.mydia.dev` routes, but the Worker is live on
`*.workers.dev` from the very first successful CI deploy):

1. Trigger a real request through the download path against a live SubDL
   subtitle (needs a working `SUBDL_API_KEY` from Step 0):
   ```bash
   curl -sS "https://<worker>.workers.dev/api/v1/subtitles/download/<file_id>"
   ```
   Repeat several times, and include at least one request against a subtitle
   archive near the top of the realistic size range (a large multi-file
   archive), not just a minimal one — the 0.30ms p99 local figure came from a
   ~10KB archive and the extraction cost scales with archive size.
2. Read the **CPU time** metric for those invocations from the Cloudflare
   dashboard (Workers & Pages → the Worker → Metrics → CPU time), not wall
   time — wall time on this route includes network I/O to `dl.subdl.com`,
   which the 10ms budget does not count.
3. Compare against 10ms.
   - **Under budget with headroom** (the local figure suggests this is
     likely, but "likely" is exactly what this step exists to stop trusting):
     no action needed, but record the real number somewhere durable (this
     README, or a follow-up note) so the next person doesn't have to
     re-derive it.
   - **Close to or over 10ms:** do not ship this route further before
     addressing it. Options in order of preference: (a) confirm the account
     is actually on a paid plan with a higher/no CPU cap before assuming
     free-plan limits apply, (b) profile `extractSubtitle` and
     `readCapped`/`declaredContentLengthExceeds` (`src/proxy/subdl.ts`) for
     the actual hot path on a large archive, (c) lower `MAX_ARCHIVE_BYTES`
     (currently 20,000,000) if real-world archives never approach it, trading
     rejected-but-legitimate edge cases for headroom.

### Step 4: production cutover (Task 16)

Everything below is **manual** and moves real traffic. Nothing in this repo
adds a production route ahead of time — `wrangler.jsonc` has no `routes` key
today, on purpose. Add it by hand, deliberately, following this sequence.

**Preconditions, all must already be true:**

- Steps 0-3 above are done: real Cloudflare resources exist (not
  `placeholder_local_dev_only`), the four secrets are set, CI has deployed at
  least once to the Worker's `*.workers.dev` subdomain, and the Step 3 CPU
  measurement has a recorded number.
- **The `/admin*` Access application from Step 1 exists and both its
  verification curls pass.** This is the ordering constraint that matters
  most in this whole runbook: neither a Worker route nor a Cloudflare Access
  application can be scoped by HTTP method, only by path. A bare
  `relay.mydia.dev/*` route (added below in 4b) exposes every path the
  Worker answers, `/admin/errors` and `/admin/feedback` included, to
  anonymous traffic the instant it deploys — regardless of what Access
  policy exists for any other path. Do not add the wildcard route on the
  assumption Access can follow "right after." If Step 1 isn't done, stop and
  do it first.
- `POST /feedback` and `POST /crashes/report` must stay reachable with no
  Access in front of them, at every point in this rollout, not just at the
  end. They are what every mydia install in the field already calls
  unauthenticated. Access is scoped to `/admin*` and only `/admin*` — never
  the hostname root, never these two paths individually.

**4a. Run the contract diff against staging, and read the output, not just
the exit code:**

```bash
cd relay-worker
CONTRACT_WORKER_URL=https://mydia-relay-staging.<subdomain>.workers.dev npm run test:contract
```

This is the real gate Step 2 above deferred out of CI. Read the summary line
before trusting it:

- If it says something like `42 skipped`, `CONTRACT_WORKER_URL` did not take
  effect (typo in the URL, wrong shell, env not exported) and this run has
  compared nothing. Vitest still exits 0 for an all-skipped run — a green
  exit code alone is not evidence anything ran. Fix the invocation and rerun
  before reading anything else into it.
- Once tests are actually running, do not proceed on a single mismatch,
  **except** these two documented, expected ones:
  - `/music/search` and `/openlibrary/search` are fuzzy-ranked. Two
    near-simultaneous identical requests can come back reordered or
    rescored against real MusicBrainz/OpenLibrary — this was observed live
    during Task 9, not theorized. A failure on either route: rerun just that
    one route in isolation before concluding the port regressed. Do not add
    retry logic to the harness itself; a silent retry would also hide a
    genuine regression.
  - `/tvdb/series/:id/episodes` returns 400 from **both** the Elixir and the
    Worker. The Elixir builds `/series/{id}/episodes/default/page/{page}`,
    which has never been a valid TVDB v4 path (TVDB's own OpenAPI spec wants
    `/series/{id}/episodes/{season-type}` with `page` as a *query* param,
    not a path segment). Nothing in mydia calls this route — the real
    client uses `/series/:id/extended` and `/seasons/:id/extended` instead
    — so it has been silently broken since it was introduced and nobody
    noticed. The Worker is deliberately bug-compatible with it. A matching
    400 on both sides here is correct, not a false pass. If this route ever
    shows a **genuine diff** (one side 400, the other something else) at a
    later cutover, that means someone fixed the Elixir's URL construction,
    not that the Worker regressed — go verify which side changed before
    treating it as a blocker, and if it's the Elixir, port the fix into the
    Worker to keep them matching.

**4b. Add production routes for the metadata paths only:**

```jsonc
  "routes": [
    { "pattern": "relay.mydia.dev/configuration", "zone_name": "mydia.dev" },
    { "pattern": "relay.mydia.dev/tmdb/*", "zone_name": "mydia.dev" },
    { "pattern": "relay.mydia.dev/tvdb/*", "zone_name": "mydia.dev" },
    { "pattern": "relay.mydia.dev/api/v1/subtitles/*", "zone_name": "mydia.dev" },
    { "pattern": "relay.mydia.dev/music/*", "zone_name": "mydia.dev" },
    { "pattern": "relay.mydia.dev/openlibrary/*", "zone_name": "mydia.dev" }
  ]
```

`cae1-1.relay.mydia.dev` is a different hostname (iroh-relay) and none of
these patterns touch it — confirm that by eye before deploying, then:

```bash
cd relay-worker && npx wrangler deploy
```

Verify from outside:

```bash
# Worker is serving, with real edge caching (not the Elixir's DYNAMIC).
curl -sI "https://relay.mydia.dev/tmdb/genre/movie?_cb=$RANDOM" | grep -iE 'cache-control|cf-cache-status'
# expect: cache-control: public, s-maxage=..., stale-if-error=...

# iroh relay still answers on its own hostname, untouched.
curl -sI https://cae1-1.relay.mydia.dev/ | head -1

# Anything not in the route list above is still the Elixir relay.
curl -sS -o /dev/null -w '%{http_code}\n' https://relay.mydia.dev/health
```

Watch Workers Logs and the Cloudflare dashboard's request analytics for at
least an hour before moving on. Rollback at this stage is removing the
routes from `wrangler.jsonc` and redeploying — the Elixir relay is still
live and still routed for everything else.

**4c. Move the remaining paths — only after the Access precondition above is
confirmed, again:**

```jsonc
  "routes": [{ "pattern": "relay.mydia.dev/*", "zone_name": "mydia.dev" }]
```

```bash
cd relay-worker && npx wrangler deploy
```

Verify pairing, crash ingest and feedback ingest end to end. Note the real
response field name below — it is `claim_code`, not `code`:

```bash
CLAIM=$(curl -sS -X POST https://relay.mydia.dev/pairing/claim \
  -H 'content-type: application/json' \
  -d '{"node_addr":"{\"id\":\"testnode\"}"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["claim_code"])')
curl -sS "https://relay.mydia.dev/pairing/claim/$CLAIM"
curl -sS -X DELETE -o /dev/null -w '%{http_code}\n' "https://relay.mydia.dev/pairing/claim/$CLAIM"

curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://relay.mydia.dev/crashes/report \
  -H 'content-type: application/json' \
  -d '{"error_type":"RuntimeError","error_message":"cutover smoke test","version":"0.0.0"}'
# expect 201, NOT 202: CrashReporter.Sender matches only 201 as success and
# retries/logs-failed on anything else.

curl -sS -o /dev/null -w '%{http_code}\n' https://relay.mydia.dev/admin/errors
# expect 302 (Access login redirect) -- confirms the smoke-test crash landed
# behind Access, not on an unauthenticated path.

curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://relay.mydia.dev/feedback \
  -H 'content-type: application/json' -d '{"type":"idea","message":"cutover smoke test"}'
# expect 201, with NO Access redirect -- this must never require login.
```

**Note on the plan document's Verification checklist:** the checklist at the
end of `docs/superpowers/plans/2026-09-05-metadata-relay-on-cloudflare-workers.md`
still says the crash report "returns 202" and appears at "`/errors`", and
that "`GET /errors` and `GET /feedback` redirect to Access" — all three are
stale. Task 15 moved both dashboards to `/admin/errors` and `/admin/feedback`
and Task 11 established 201 as the only success status the real producer
accepts; this section supersedes that checklist. Use the commands above, not
that list, when actually running the cutover.

Commit only `relay-worker/wrangler.jsonc` once the whole hostname is moved
and stable — see the plan's Task 16 Step 5 for the commit message shape.

### Step 5: decommission the Elixir relay on can-1 (Task 17)

Do not start this until Step 4 has been stable in production for real
traffic. This is a staged, mostly-irreversible sequence — read it end to end
before running the first command. The ordering below is deliberate: each
stage is either reversible in seconds or a pure archival step, right up
until the last one, which is neither.

**5a. Soak with the Elixir relay running but unrouted, at least 7 days.**
Once Step 4c lands, `relay.mydia.dev` no longer sends the Elixir pod any
traffic, but nothing has stopped it. Leave it running. Confirm from Workers
Logs that the Worker is serving every route and that error rates match the
pre-cutover baseline. The pod costs nothing while idle and it is the entire
rollback plan for this stage — if anything looks wrong, the fix is
re-pointing `wrangler.jsonc`'s routes back, not touching can-1 at all.

**5b. Archive the crash history — from the host path, never from inside the
pod.**

```bash
ssh root@can-1 'cp /var/lib/rancher/k3s/storage/pvc-*_metadata-relay_metadata-relay-data/metadata_relay.db /var/tmp/metadata_relay_archive.db'
scp root@can-1:/var/tmp/metadata_relay_archive.db ~/archive/
ssh root@can-1 'rm /var/tmp/metadata_relay_archive.db'
```

Two details in that command are load-bearing, not stylistic:

- **Copy from the host filesystem, not `kubectl exec` into the pod.** The
  pod's memory limit is 512Mi and the database is roughly 634MB; opening or
  querying it in-pod has OOM-killed this service in production before. A
  plain host-side `cp` never loads the file into the container's memory at
  all.
- **Use `/var/tmp`, not `/tmp`.** `/tmp` on can-1 is a 3.8G tmpfs on a 7G
  box — copying a 634MB database into it is a meaningful fraction of total
  RAM on a host that is not provisioned for that spike. `/var/tmp` is
  regular disk.

**5c. Dump the live k8s secret before running `infra/deploy` again for any
reason, and before Step 5d touches it.**

```bash
ssh root@can-1 'sudo k3s kubectl get secret metadata-relay-secrets -n metadata-relay -o yaml' \
  > metadata-relay-secrets-backup.yaml
```

`infra/deploy`'s `metadata_relay_secret_data()` (`infra/deploy:1027`) only
knows five keys: `RELAY_TOKEN_SECRET`, `TMDB_API_KEY`, `TVDB_API_KEY`,
`SMTP_PASSWORD`, `SUBDL_API_KEY`. If the live secret has ever been hand-edited
(`kubectl edit secret ...`) to add or rotate something this function was
never taught about, that value exists only on the live cluster object —
nowhere in this repo, nowhere in `infra/config.yaml`. Step 5d below deletes
the entire `metadata-relay` namespace, which deletes the Secret outright.
Take this backup before that point; there is no merge or patch semantics to
save an unknown key from a namespace deletion.

**5d. Scale to zero and wait 48 hours before deleting anything.**

```bash
ssh root@can-1 'sudo k3s kubectl -n metadata-relay scale deploy/metadata-relay --replicas=0'
ssh root@can-1 'sudo k3s kubectl -n metadata-relay scale deploy/redis --replicas=0'
```

Scaling to zero is reversible in seconds (`--replicas=1`). Nothing after
this point is.

**5e. Delete the manifests, the namespace, and the `infra/deploy` entry —
last, and only after 5b and 5c are confirmed done:**

```bash
ssh root@can-1 'sudo k3s kubectl delete namespace metadata-relay'
git rm infra/kubernetes/apps/metadata-relay/{deployment,redis,pvc,service,ingress,configmap,secret.yaml.example}.yaml
```

Update `infra/kubernetes/apps/metadata-relay/kustomization.yaml` to drop the
removed resources (or delete the directory entirely if nothing remains), and
remove the metadata-relay entry from `infra/deploy`'s
`metadata_relay_secret_data`/`metadata_relay_configmap_data`/`phase_metadata_relay`
so a future `infra/deploy` run does not try to recreate what was just torn
down.

Deleting the namespace deletes the PVC and everything on it. This is the one
genuinely irreversible step in this whole runbook — it must come after 5b
(archive taken), 5c (secret backed up) and 5d (48-hour soak at zero replicas
with no surprises), never before.

**5f. Retire the Elixir service source and its CI.**

Delete `metadata-relay/` and `.github/workflows/ci-relay.yml`, remove the
`docker` job from `.github/workflows/deploy-relay.yml` (leaving only
`deploy-worker`), and rename that file to `deploy-relay-worker.yml`.

**Before doing this, understand what it costs:** `metadata-relay/`'s source
is the reference implementation this entire Worker port was verified
against, task by task, for 15 tasks — every route table, every TTL, every
edge case (the SubDL field names, the pairing `claim_code` shape, the
crash-report status code, the CORS preflight behaviour) was confirmed
correct by reading that code, not by guessing. Deleting the directory
removes the ability to answer any future "does the Worker actually match
what the Elixir did here" question by reading source — git history still
holds every line (`git log --all -- metadata-relay/`, or check out the last
commit before this deletion), but that is a materially higher-friction path
than a file in the working tree, and it is easy to forget the history is
there at all once the directory is gone from `HEAD`. Make sure whoever runs
this step knows that trade before running `git rm -r metadata-relay/`.

**5g. Update the docs.** `lib/mydia/metadata/README.md`: note that
`relay.mydia.dev` is now a Worker, and that the `append_to_response`
behaviour it documents is preserved by the no-allowlist forwarding rule in
`relay-worker/src/proxy/forward.ts`. `AGENTS.md`'s Metadata Relay Service
section: point it at `relay-worker/` and `wrangler deploy` as the deploy
ritual — as of this writing that section doesn't actually name the old
`metadata-relay-v*` tag or Keel, so there is nothing incorrect to remove
there, only `relay-worker/` to add.

## Brief vs. reality

This task's brief (`task-15-brief.md`) assumed several things that don't
match this repository as it stands. Recorded here so the next person doesn't
re-discover them the hard way:

- **The Access path split as specified (`/errors` and `/feedback`) doesn't
  work.** See Step 1 above — Access matches by path only, not method, and
  `/feedback` used to serve both the public POST and the dashboard GET on the
  identical path. Fixed by moving both dashboards under `/admin/*`, a path no
  public endpoint shares. This was the biggest gap found in this task;
  everything else below is comparatively minor.
- **"The Cloudflare API token and zone id already exist in
  `infra/config.yaml`; add them as repository secrets if they are not there
  yet"** conflates three different things:
  - `infra/config.yaml` is a **local, git-ignored** operator file consumed by
    the `infra/deploy` Python tool. Nothing in it is automatically a GitHub
    Actions secret; there is no sync between the two.
  - Its `cloudflare_api_token` is scoped to **`Zone:DNS:Edit`** only (see
    `infra/README.md`'s setup instructions), for `external-dns`. It has no
    permission to deploy a Worker, write D1, or write KV — reusing it as-is
    would make `wrangler deploy` fail with an authorization error.
  - It stores a **zone ID**, not an account ID. `wrangler` needs
    `CLOUDFLARE_ACCOUNT_ID` (an account identifier), a different Cloudflare
    resource entirely; a zone ID doesn't work for that env var.
  - Separately, `CLOUDFLARE_API_TOKEN` **does already exist** as a GitHub
    Actions repository secret — but for `wrangler pages deploy` in
    `deploy-site.yml`/`deploy-web-player.yml`, a different scope again (Pages
    edit, not Workers/D1/KV edit).
- **`d1_databases[0].database_id` and `kv_namespaces[0].id` are
  placeholders**, not real Cloudflare resources — `wrangler.jsonc`'s own
  comments say so. The brief's CI snippet assumes `wrangler d1 migrations
  apply --remote` and `wrangler deploy` just work once secrets exist; they
  don't, until the D1 database and KV namespace are actually created (Step 0
  above) and the placeholder IDs are replaced.
- **Action versions.** The brief's Step 2 snippet uses
  `actions/checkout@v4` and `actions/setup-node@v4`. This repository's own
  workflows (including the `docker` job already in this same file) use
  `@v7` for both; the shipped workflow matches the repository's convention
  instead.
- **Adding a bare `paths:` filter to the existing tag-triggered push block
  would have been a silent trap**, not the drop-in change Step 3 describes —
  except it turns out fine, for a documented reason: GitHub Actions does not
  evaluate `paths` filters on tag pushes at all, only on branch pushes. So
  adding `paths: ["relay-worker/**"]` alongside the existing `tags:` trigger
  doesn't gate the Docker job's tag trigger — but it does mean the workflow
  now *also* fires on branch pushes, which it never did before. Without an
  `if:` guard, that would make a relay-worker-only commit to `master` also
  invoke the unrelated `docker` job, which parses a semver out of the ref and
  would receive a branch ref instead of a tag — producing a broken Docker
  build on every such commit. Both jobs in the shipped workflow carry
  `if:` guards (`startsWith(github.ref, 'refs/tags/')` for `docker`,
  `github.ref_type == 'branch'` for `deploy-worker`) to prevent this.
- **No PR-time CI signal exists for `relay-worker/` yet.** Unlike
  `metadata-relay/` (covered by `ci-relay.yml` on every push and PR), there
  is no equivalent workflow running `npm test`/`npm run typecheck` against
  `relay-worker/**` on pull requests. The `deploy-worker` job added here
  only runs after a merge to `master`, and it is safe (a failing test/
  typecheck step stops the job before `wrangler deploy` runs), but it means a
  broken PR currently gets no automated feedback before merge — only after.
  This wasn't in Task 15's authorized scope (CI/README only); flagging it as
  a gap worth a small follow-up rather than fixing it here.
- **The Step 6 CPU measurement was never performed**, for the reason stated
  in Task 6's report: it needs a deployed Worker, which didn't exist yet.
  See the runbook's Step 3 above.
- **Task 16 Step 4's own pairing-verification snippet reads the wrong JSON
  field.** It parses the claim response as `["code"]`; the route actually
  returns `{"claim_code": "..."}` (`src/pairing/routes.ts`, and confirmed
  against both `remote_access.ex` and the Flutter client during Task 10) —
  the original snippet would `KeyError` before ever reaching the GET/DELETE
  checks. Fixed in this runbook's Step 4c.
- **The plan's final "Verification checklist"** (the very end of the plan
  document, distinct from Task 16 Step 4's own inline verification, which
  Task 15 already corrected) **was never updated for the `/admin/*` move or
  the 201 status code.** It still says a crash report "returns 202" and
  appears at "`/errors`", and that "`GET /errors` and `GET /feedback`
  redirect to Access" — all three predate Task 11 (201 is the only status
  the real producer accepts) and Task 15 (both dashboards moved to
  `/admin/*`). This runbook's Step 4c commands are the corrected version;
  do not run the plan document's own checklist verbatim.
