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
| Cron Trigger `0 * * * *` | scheduled | `wrangler.jsonc` (`triggers.crons`) | Hourly sweep (`src/obs/sweep.ts`): evicts stale `feedback_rate_limits` rows and expired `pairing_claims` |

`ratelimits[].namespace_id` values (`1001`-`1003`) are arbitrary identifiers
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
