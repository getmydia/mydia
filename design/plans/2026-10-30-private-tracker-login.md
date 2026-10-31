# Private-tracker login hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run whole private-tracker journeys (configure, log in, search, grab,
session expiry) against three Bypass-backed fictional trackers on both Cardigann
engines, and fix every gap they expose.

**Architecture:** Three invented definitions live as YAML fixtures under
`test/support/fixtures/private_trackers/`, each shaped like an upstream family
(UNIT3D API, Gazelle form login, NexusPHP-style captcha + 2FA form). A small
support module (`Mydia.PrivateTrackerFixtures`) inserts a definition pointed at
a Bypass port and stubs the tracker. Journey tests drive the public entry points
(`Indexers.configure_cardigann_definition/2`, the adapter `search/3`, the
Indexers LiveView login modal, `Downloads.initiate_download/2` against a
blackhole client) and assert on stored sessions, health status, logs and the
`downloads` row. The WASM journeys reuse the fixtures under the
`:cardigann_wasm` tag, which the suite excludes when the guest is missing.

**Tech Stack:** Elixir, ExUnit, Bypass, Phoenix.LiveViewTest, Wasmex guest
(`Mydia.Indexers.Cardigann.Wasm.Adapter`).

Roadmap spec: `design/specs/2026-10-30-private-trackers-roadmap-design.md`,
section "Spec 3: Login hardening" (on the `feat/tracker-terms` branch).

## Global Constraints

- No real tracker names or real titles in code, tests or fixtures. Family names
  (UNIT3D, Gazelle, NexusPHP) are fine.
- Spec 0 (terms, seeding rules, freeleech, overrides) is out of scope: do not
  assert `SearchResult.terms`; docs mention those at most as coming.
- No em dashes in docs, comments or commit messages.
- Every user-visible string through gettext; unique DOM ids; LiveView tests use
  `has_element?`.
- `docs/` is end-user documentation; this plan stays in `design/`.
- Never run `mix precommit` or the full suite; run the touched files.

---

## File structure

| Path | Responsibility |
| --- | --- |
| `test/support/fixtures/private_trackers/*.yml` | the three invented definitions |
| `test/support/private_tracker_fixtures.ex` | insert a definition at a Bypass base, stub each tracker, a private `.torrent` body |
| `test/mydia/indexers/private_tracker_journey_test.exs` | built-in engine journeys |
| `test/mydia/indexers/cardigann/wasm/private_tracker_journey_test.exs` | WASM engine journeys (`@moduletag :cardigann_wasm`) |
| `test/mydia_web/live/admin_indexers_live/private_tracker_login_test.exs` | challenge round trip from the Indexers page, and the engine note |
| `lib/mydia/downloads/torrent_fetch.ex` | log lines that carry a URL or a torrent body (gap fixes) |
| `lib/mydia/indexers/cardigann/wasm/adapter.ex` | person-needed login under WASM (gap fix, if the probe shows one) |
| `lib/mydia_web/live/admin_indexers_live/*` | engine note for captcha/2FA definitions (if needed) |
| `lib/mydia/indexers/cardigann_compat.ex`, `lib/mix/tasks/mydia.cardigann_compat.ex` | supported/unsupported login-method summary |
| `docs/using/how-to/cardigann-indexers.md` | private trackers how-to and counts |
| `lib/mydia/indexers/README.md` | record the WASM login behaviour and the journey tests |

## Task 1: Fixtures for three invented private trackers

**Files:**
- Create: `test/support/fixtures/private_trackers/emberline-api.yml` (UNIT3D)
- Create: `test/support/fixtures/private_trackers/vellum.yml` (Gazelle)
- Create: `test/support/fixtures/private_trackers/harrowgate.yml` (NexusPHP-style captcha + 2FA)
- Create: `test/support/private_tracker_fixtures.ex`

**Interfaces:**
- Produces: `Mydia.PrivateTrackerFixtures.insert!(name, bypass, config \\ %{}) :: CardigannDefinition.t()`,
  `stub_unit3d(bypass, opts)`, `stub_gazelle(bypass, opts)`, `stub_captcha(bypass, opts)`,
  `private_torrent(passkey) :: binary()`, `adapter_config(definition) :: map()`.
  Stubs `send(test_pid, {:tracker, event, data})` for login, search and download
  hits so tests can count them; `opts[:expire_after]` makes the search answer
  logged out after N searches with the current session.

Shapes, matching upstream:

- UNIT3D: `login: {method: get, path: api/torrents}` with the error selector
  on `a[href*="/login"]`; `search.headers.Authorization: Bearer {{ .Config.apikey }}`;
  path `api/torrents/filter` with `response.type: json`; rows `data` attribute
  `attributes`; download `download_link`, which the tracker returns as
  `/torrent/download/<id>.<rsskey>`. The spec says "API key in the query";
  upstream UNIT3D moved it to the Authorization header, so the fixture follows
  upstream and the rsskey rides in the download URL path.
- Gazelle: `login: {method: form, path: login.php, form: form#loginform,
  selectorinputs: {auth: {selector: input[name=auth], attribute: value}}}`,
  test selector `a[href^="logout.php"]`; search `torrents.php` HTML
  `table#torrent_table`; download href
  `torrents.php?action=download&id=..&authkey=..&torrent_pass=<passkey>`.
- Captcha + 2FA: `login: {method: form, path: login.php, submitpath: takelogin.php,
  captcha: {type: image, selector: img[alt="CAPTCHA"], input: imagestring},
  inputs: {two_step_code: "{{ .Config.2facode }}"}}`, test `a[href="logout.php"]`.

- [ ] Write the fixtures and the support module; `mix compile` in test env.
- [ ] Commit `test(indexers): invented private tracker fixtures`.

## Task 2: Built-in journeys (configure, login, search, expiry)

**Files:** Test: `test/mydia/indexers/private_tracker_journey_test.exs`

- [ ] UNIT3D: configure with an API key, search sends `Authorization: Bearer <key>`,
  results parse; a login failure (no key) is an authentication error.
- [ ] Gazelle: configure username/password, first search logs in once (POST
  carries the scraped `auth` token, credentials), stores the session, search
  sends the cookie, second search does not log in again.
- [ ] Gazelle expiry: tracker answers logged out once; the next search re-logs
  in exactly once and returns rows.
- [ ] Captcha: first search with no session parks the definition in
  `needs_login` and returns `:login_required` with no POST sent.
- [ ] Captcha expiry: stored session works, tracker expires it, re-login meets
  the captcha, definition moves to `needs_login`, later searches send nothing.
- [ ] Run; any failure is a gap: fix it in the module the failure points at
  (TDD: the journey is the failing test), commit fix and test together
  (`fix(indexers): ...`), otherwise `test(indexers): ...`.

## Task 3: Challenge round trip from the Indexers page

**Files:** Test: `test/mydia_web/live/admin_indexers_live/private_tracker_login_test.exs`

- [ ] Captcha tracker in `needs_login`: click `#indexer-login-<id>`, modal shows
  the captcha image and the `#indexer-login-field-2facode` input; submit both;
  the POST goes to `takelogin.php` (the submitpath) with `imagestring` and
  `two_step_code`; the session is stored, status is `healthy`, the next adapter
  search sends the stored cookie.
- [ ] Commit.

## Task 4: Grab with the session or key, passkey kept out of logs

**Files:**
- Modify: `lib/mydia/downloads/torrent_fetch.ex`
- Test: in `private_tracker_journey_test.exs`

- [ ] For the Gazelle and UNIT3D trackers, grab the first search result through
  `Downloads.initiate_download/2` with a blackhole client and `Logger` at
  `:debug`: the tracker sees the session cookie (Gazelle) or the rsskey URL
  (UNIT3D); the file written to the watch folder is byte-identical to the
  private torrent served (so `ensure_torrent_trackers/1` left it alone, and
  `ensure_trackers/1` is a no-op on a non-magnet); captured logs contain neither
  the passkey, the rsskey, the API key nor the session cookie value; the
  `downloads` row's `error_message` and the `download.initiated` event carry no
  passkey.
- [ ] Expected failures: `TorrentFetch` logs the full URL
  ("Downloading file from URL: ...") and a 500-character preview of the body,
  whose announce URL holds the passkey. Fix: log the URL's origin only and drop
  the body preview for torrents. A failed fetch also logs the URL and body; use
  the origin there too.
- [ ] Decision recorded: `downloads.download_url` keeps the raw URL, since
  re-grab (`DownloadsLive.Retry.regrab/1`), duplicate detection and prior
  attempts match on it, and a redacted Gazelle URL cannot be restored (the
  authkey is not a setting). Rendering it redacted is Spec 4.
- [ ] Commit `fix(downloads): keep tracker passkeys out of grab logs`.

## Task 5: WASM engine journeys

**Files:** Test: `test/mydia/indexers/cardigann/wasm/private_tracker_journey_test.exs`

- [ ] Probe first: with the captcha tracker and no stored session, what does
  `Wasm.Adapter.search/3` return, and does it call the captcha URL? With an
  expired stored session? Record the answer in the README.
- [ ] Journeys: UNIT3D search with the key; Gazelle login + search + expiry
  re-login; a session stored by the built-in login (the Indexers page) is
  reused by the WASM search; captcha on re-login.
- [ ] If WASM swallows the captcha into an empty result: gap. Fix in
  `Wasm.Adapter`: a definition whose login needs a person (image captcha, or
  inputs referencing a 2FA key, same rule as `Login.Form`) is never handed to
  the guest without a stored session; it moves to `needs_login` like the
  built-in engine, and an empty answer after the guest replaced a stored
  session for such a definition does the same. If that is not reliable, the
  Indexers page says captcha and 2FA logins need the Built-in engine.
- [ ] Commit.

## Task 6: Compat counts and docs

- [ ] `mix mydia.cardigann_compat --type private --cache`; extend the report
  with supported vs unsupported login methods (supported: the methods
  `Login.begin/2` dispatches, plus `none`) and captcha / 2FA counts.
- [ ] Rewrite the private-tracker parts of
  `docs/using/how-to/cardigann-indexers.md`: comparison row, a "Private
  trackers" section (cookie, form, API key setup; captcha and 2FA via Log in;
  `needs_login`; the counts; ask for reports), remove "CAPTCHA not supported"
  and "2FA not supported".
- [ ] Update `lib/mydia/indexers/README.md` (journey tests, WASM login note).
- [ ] Commit `docs(indexers): private trackers how-to`.
