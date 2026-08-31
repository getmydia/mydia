# Reading CI, and the flake catalogue

The rule for any red check: read the actual failing job and test name before
assuming your diff broke something, then check whether master is red on the same
job.

```bash
gh run list --repo getmydia/mydia --branch master --workflow "<workflow>" --limit 5
```

A red master means the branch inherited the breakage. CI tests the merge of the PR
into master, so a branch behind master pulls master's commits into the tested
tree. The cheapest proof of flakiness is one SHA with both a passing and a failing
run. Re-run with `gh run rerun <id> --failed`, which needs the run to be
`completed` first.

## Before anything else: did CI run at all?

A PR whose `mergeStateStatus` is `DIRTY`, meaning it conflicts with the base
branch, never triggers `pull_request` workflows. GitHub cannot compute the merge
ref those workflows run against, so zero check-runs are created. `gh pr checks <n>`
then prints `no checks reported on the '<branch>' branch`, which reads exactly like
"CI has not started yet". Waiting produces nothing, forever.

`ci.yml` triggers on `pull_request: branches: ["**"]`, and that filter matches the
base branch, so it is not the cause. The conflict is. When a PR shows no checks
after a few minutes, run `gh pr view <n> --json mergeable,mergeStateStatus` before
investigating Actions permissions, workflow triggers or `gh` itself.
`CONFLICTING`/`DIRTY` is the answer; merge or rebase the base branch in, push, and
checks register immediately.

Master moves fast here, 39 commits in under a day during one session, so a branch
cut from `origin/master` can be conflicting by the time its PR opens. Verify
`mergeable` right after `gh pr create`.

A conflicted PR is not silent, which is what makes it hard to spot. On PR #596
(2026-08-28) the CodeQL workflow still ran and reported `Analyze (ruby)`,
`Analyze (rust)` and `CodeQL` as green, and CodeRabbit still reviewed, so
`gh pr checks` showed a page of passes while `Test`, `Test / PostgreSQL`, `Rust`,
`Site build` and E2E were absent entirely. Not pending, not failing, just not
there. Two pushes looked like a slow queue for about 40 minutes.

Never conclude green from "nothing failed". Assert the named jobs are present and
passing:

```bash
gh pr checks <n> --repo getmydia/mydia --json name,bucket --jq '
  ["Test", "Test / PostgreSQL", "Test / E2E Browser", "Site build",
   "Load lanes (ios)", "Load lanes (android)"] as $need
  | (map(select(.bucket=="pass") | .name)) as $passing
  | ($need - $passing)'
```

The same trap bites a watch loop built on `all(.bucket != "pending")`, which is
trivially true over a subset that never included the suites.

`gh run list --branch <name>` is unreliable here; it omitted the CodeQL runs that
`gh pr checks` was plainly showing. The authoritative per-commit query is
`gh api repos/getmydia/mydia/commits/<sha>/check-runs`, and
`gh run list --workflow ci.yml --limit N` confirms whether the main CI workflow ran
for a given head SHA at all.

Also note `cancel-in-progress: true` in that workflow's concurrency group: pushing
a new commit cancels the in-flight run, so a `gh pr checks --watch` started on the
old head exits with a truncated view. Re-watch after each push.

## Only six checks are required

The Master ruleset (`gh api repos/getmydia/mydia/rulesets/9740184`) requires
exactly six status checks:

```text
Test, Test / PostgreSQL, Test / E2E Browser, Site build,
Load lanes (ios), Load lanes (android)
```

Everything else is advisory, including `Test / Player`, `Build / Web`,
`Build / Android`, `Build / Linux`, `Build / macOS`, `Build / Windows`,
`Flatpak / Build`, `Rust`, every `Check / *`, and the lockfile scanners.

GitHub required-status-checks block forever on a context that never reports, and
those workflows are path-filtered at the workflow level (`ci-player.yml`'s
`on.pull_request.paths`), so a PR touching no `player/**` file would hang on an
Expected check. The short list is the workaround, and `dependabot-auto-merge.yml`'s
own comment says so.

`gh pr merge --auto` waits on required checks only, with no flag to consider
advisory ones, so a dependabot PR can merge with a wall of red. PR #613
(`flutter_secure_storage` 10.3.1 to 11.0.0) merged 2026-08-29 with seven red checks
(Build/Web, Test/Player, Build/Android, Build/Linux, Build/Windows, Build/macOS,
Flatpak/Build) and broke the master Docker image, because v11 removed
`AndroidOptions.encryptedSharedPreferences`.

Do not describe a break like that as "the PR gate missed it". The gate fired
loudly and nothing was listening. When triaging a merged-but-broken commit, check
the PR's full check list rather than whether it merged green.

Making a path-filtered job requirable needs a shim: move the path filter into a
`changes` job and gate downstream work with a step-level `if:`, never job-level. A
job-level `if:` concludes `skipped`, and a skipped required check is ambiguous to
rulesets.

## CI / Docker cancels its own master runs

`ci-docker.yml` sets `cancel-in-progress: true` on a ref-keyed group and is
push-only on master, so consecutive merges cancel each other's image builds. On
2026-08-29 the runs for #577, #612 and #613 were all cancelled, and the first to
survive was #611's, which inherited a break introduced by #613.

Before bisecting a Docker failure, list the runs and note which SHAs have no
completed run at all:

```bash
gh run list --workflow=ci-docker.yml --branch=master --json headSha,conclusion,createdAt
```

The last-green boundary is real, but the first observed red is not necessarily the
culprit.

## Waiting on checks without being fooled

The rollup can read all-green before the two `Test / NixOS Module` checks
register, so double-sample before treating a PR as ready.

The obvious wait loop, `until ! gh pr checks <n> | grep -q pending`, returns
instantly having waited for nothing in three situations, because empty stdout
matches nothing and so satisfies the negation:

1. Right after `gh pr create`, when no checks are registered yet.
2. On a transient `gh` failure that prints only to stderr, seen as
   `net/http: TLS handshake timeout`.
3. Right after pushing a new commit to an existing PR, when the previous run's
   checks are superseded and the new run's have not registered. This is the
   dangerous one, since it fires on a PR that was green moments earlier, so an
   automated merge reads a stale green and lands a commit whose CI never ran.

Require non-empty output, then re-list and confirm `headRefOid` matches the commit
you pushed. Keep this in a script file, since the worktree guard rejects the loop
as an inline Bash command:

```bash
while true; do
  head=$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid 2>/dev/null)
  out=$(gh pr checks "$pr" --repo "$repo" 2>/dev/null)
  if [ "$head" = "$pushed_sha" ] && [ -n "$out" ] &&
     ! printf '%s' "$out" | grep -q pending; then
    break
  fi
  sleep 60
done
```

The `headRefOid` comparison is the part that matters: without it the loop can
break on a complete-looking run that describes the previous commit.

## Infrastructure and network failures

**Nix asset downloads**, on any Nix job. Fails with `cannot download ... from any
mirror` or `curl: (22) ... 503`, then cascades into a wall of
`Reason: 1 dependency failed` that looks alarming and means nothing. The root
enabler is visible earlier in the same log:
`ERROR magic_nix_cache: FlakeHub: cache initialized failed: Unauthenticated`. With
no binary cache every job re-fetches from the release CDN and is exposed to any
wobble. The failing asset varies (wasmex NIF, the Tailwind binary, a bare
`source>` derivation), so grepping for `libwasmex` reports zero matches on a job
that failed for exactly this reason. Grep `cannot download|curl: \(` instead. It
hits different jobs on different runs of the same commit, which is the tell.

**crates.io 403.** Nix vendors Rust crates via `fetch-cargo-vendor-util`, and that
step intermittently returns `Status code: 403` on a crate download, ending in
`error: Build failed due to failed dependency`. The Python traceback looks like a
build error but the root line is always an HTTP status.

As of 2026-08-26 this mode is persistent on `Test / NixOS Module` rather than
intermittent. After #584 cleared the `npmDeps.hash` mismatch that had been
aborting the build earlier, master's two NixOS Module jobs failed three re-runs in
a row at `e5fd485f0`, each in 90s to 2min, each on a different crate:
`crate-data-encoding-macro-0.1.20`, then `crate-noq-1.1.1` /
`crate-objc2-core-wlan-0.3.2` / `crate-noq-proto-1.1.1`, then `crate-netdev-0.45.0`.
The surface error is `crate-<name>> error: cannot download crate-<name>-<ver>.tar.gz
from any mirror`, and the real line is a few lines above it,
`curl: (22) The requested URL returned error: 403`. The varying crate name is the
tell that it is not a specific bad dependency.

Check the root enabler first: `##[error]Unable to authenticate to FlakeHub` plus
GitHub's own cache returning `HTTP error 418` or
`TwirpErrorResponse { code: ResourceExhausted, msg: "rate limit exceeded" }` on
every narinfo lookup. With no binary cache at either layer, every job re-fetches
every crate from crates.io and gets rate-limited. Do not budget more than one
re-run on this until the FlakeHub auth is fixed; that is the actual repair.

**Flatpak / Build and code.videolan.org.** The manifest fetches libplacebo
straight from VideoLAN's GitLab, which has timed out from Actions runners
(`Failed to connect to code.videolan.org port 443`). Re-running does not clear that
mode.

This recovered as of 2026-08-22, verified on PR #533, and #507 passed it in 11m58s
on 2026-08-19, so do not assume the check is red. Treat a red `Flatpak / Build` as
a real signal and read the log; only the
`Failed to connect to code.videolan.org port 443` signature is this mode. The
underlying fragility is untouched, since the manifest still pulls libplacebo from
that single host (`player/flatpak/dev.mydia.player.yml:79`). Tracked in
getmydia/mydia#534.

The same job has a second, genuinely transient mode further along.
`player/flatpak/smoke-test.sh` runs the built Flatpak under Xvfb and asserts it
survives 10 seconds. It can report `::error::Player exited within 10 seconds` with
only environmental noise (`libEGL warning: DRI3 error`,
`libsecret_error: KeyringLocked`) and no Dart exception. That script exists to
catch unresolvable shared libraries, `libmpv` above all, so if the log has no
`error while loading shared libraries` or `cannot open shared object`, it did not
catch what it is there to catch. The two modes are sequential, so clearing the
first can expose the second; be willing to re-run twice.

**Build / Linux can hang indefinitely on "Install Linux dependencies".** Seen
2026-08-19 on PR #507, where the job sat in that step for 90+ minutes while
Windows (11m), macOS (13m) and Android (17m) all finished. Master's `Build / Linux`
completes in about 6.5 minutes, which is the comparison that identifies it. It
never fails on its own, so it will not trip a wait-for-failure loop and will sit
until the 6-hour job timeout. Recovery is `gh run cancel <id>`, poll until
`status=completed`, then `gh run rerun <id> --failed`; the rerun passed in 9m4s.
Check the in-progress step name before assuming a long job is doing work:

```bash
gh api repos/getmydia/mydia/actions/jobs/<job-id> --jq '.steps[] | select(.status=="in_progress") | .name'
```

The same hang hit `Flatpak / Validate metadata` on "Install validators" for two
hours on PR #509 while the other 14 checks passed. `updated_at` on the job stayed
frozen at one minute after `started_at`, which is the cheapest tell that nothing is
running, and master's copy of the same job succeeded an hour into the hang. Treat
any "Install <deps>" step as the suspect when a job outlives its siblings.

**Test dies building a wasm plugin, with no error text at all.** Seen 2026-08-28
on PR #593, where the `Test (SQLite) under devenv` step printed

```text
[plugins] compiling simkl_sync -> priv/plugins/simkl_sync.wasm
[plugins] compiling webhook_notifier -> priv/plugins/webhook_notifier.wasm
##[error]Process completed with exit code 1.
```

and stopped at 2m43s, before a single test ran. There is no `error:`, no
`cannot download`, no crate name, and grepping the log for any failure keyword
returns nothing but unrelated `::error::` strings from the guard steps' own `echo`
lines. The only tell is the runtime: a healthy `Test` job is about 20 minutes, so a
sub-3-minute red on `Test` means it died in setup. Re-running cleared it and the
same SHA then compiled both plugins fine. Check the diff for `native/`, `*.rs`,
`Cargo*`, `priv/plugins/` or `*.nix` first; if it touches none of them, it cannot
have affected the wasip2 component build.

**Setup Flutter fails in about 25s with `Process completed with exit code 35`**, on
any `ci-player.yml` job. Seen 2026-08-30 on PR #621.
`subosito/flutter-action@v2` shells out to curl to fetch the SDK, and exit 35 is
`CURLE_SSL_CONNECT_ERROR`, a TLS handshake failure against the download host. The
job dies before `flutter pub get`, so every later step shows `skipped` and the
surface reading is "the whole build was skipped" rather than "one download
failed". The tell is the runtime, since a real `Build / Web` takes 2 to 4 minutes.
Get the per-step breakdown before reading logs, which works while the run is still
going:

```bash
gh api repos/getmydia/mydia/actions/jobs/<job-id> --jq '.steps[] | "\(.conclusion // .status)\t\(.name)"'
```

## Elixir test flakes

`Mydia.DataCase` forces `async: false` on SQLite but honours `async: true` on
Postgres, so the Postgres job runs modules concurrently and is where order- and
config-leak-sensitive tests surface. Any change that shifts suite timing, even one
extra query per LiveView mount, can expose a latent one without being its cause.

### Postgres job

**`CrashReporter.TowerReporterTest`**, high rate, roughly 3 in 5 runs. Fails
`assert wait_until(fn -> Queue.count() >= 1 end)`, a 2s poll, and a different test
in the module fails each run, which is the tell that it is timing rather than a
regression. The cause is setup mutating process-global state via
`System.put_env("CRASH_REPORTING_ENABLED"/"METADATA_RELAY_URL")`; despite
`async: false` the reporting Task runs in a separate process, so the env has to be
global and leaks across concurrently-scheduled work. Two wrong theories cost real
time before anyone read the setup block, "just a flake" and "my heavy tests starve
it". The real fix is injecting config instead of env vars.

**`MydiaWeb.ChangelogBannerTest`**, "adopts the newest version silently on first
mount" (`changelog_banner_test.exs:48`). Fails as `ExUnit.TimeoutError` after
60000ms on `refute has_element?(view, "#changelog-banner")`, with the stack ending
in `GenServer.call` via `Phoenix.LiveViewTest.call/2`. A hang rather than a wrong
assertion, which is the tell. Same first-mount adoption race as
`Accounts.ChangelogPreferenceTest`, seen from the LiveView side; the module is
`async: false` but other modules run concurrently around it on Postgres. Confirmed
flaky on PR #483, where the identical SHA `7cb9b456` failed then passed on
`gh run rerun --failed`.

At least two tests in this module flake this way, so match on the signature rather
than the test name. The sibling "shows no banner to a user who is current"
(`changelog_banner_test.exs:40`) failed identically on master after PR #505 merged,
in a run whose diff was entirely under `lib/mydia/downloads/`. Post-merge `CI` on
master is where this bites: `CI / Docker`, `CI / Nix` and `CI / Player E2E` all
stay green while `CI` alone goes red on 1 failure out of about 8490.

**`Indexers.Adapter.CardigannTest`**, "search purges an expired FlareSolverr
session and does not crash". Fails the final
`refute Repo.get(CardigannSearchSession, ...)`, reporting the still-present row.
The purge is a side effect of the session lookup inside `Cardigann.search/2`, so
anything making the search short-circuit leaves the row behind, and the log carries
`Req.TransportError connection refused` warnings around it. SQLite green on
identical code.

**`Indexers.CardigannTemplateTest`**, "logging logs info on parse error". Caught on
a PR whose diff was entirely under `player/`.

**`Accounts.ChangelogPreferenceTest`**, racing concurrent first-mount insert; exits
on `Task.await_many(tasks, 2_000)` timeout. The assertion budgets 2 seconds for two
racing tasks, not enough on a loaded runner, though the file runs in 0.1s locally.
The proper fix is raising the timeout.

**`Playback.OnDeckTest`**, "the query count does not grow with the number of
engaged shows". Do not use inverted numbers as the tell. It first appeared as 9 for
3 shows and 6 for 15, which no regression produces, but recurred as 8 for 3 and 12
for 15, which reads exactly like a genuine N+1. Triage by what the diff touches
instead. The counter picks up other modules' queries, so it is Postgres cross-test
pollution; the proper fix is scoping the telemetry counter to the test's own repo
checkouts.

**`Playback.DismissalTest`**, "dismiss_from_on_deck/3 emits no event, where an
unwatch would", seen 2026-08-23 on PR #541. Sibling of `Playback.OnDeckTest` and
behaves the same way: 1 failure out of 8792, with `Ecto.StaleEntryError` and
`Postgrex.Protocol ... disconnected` noise in the same log. The PR's diff was four
files, all under `player/`, zero Elixir, and the same job had passed on the
immediately preceding commit with an identical Elixir tree.

**`Media.MediaTest`**, "a duplicate match deterministically picks the earliest
inserted row". Fails `assert id == older.id` with two different UUIDs. This one has
a real root cause: `external_id_match/2` (`lib/mydia/media.ex`) does
`order_by([m], asc: m.inserted_at) |> limit(1)`, while `MediaItem` declares
`timestamps(type: :utc_datetime)`, second precision. Two rows inserted in the same
second are an exact tie, so PostgreSQL may return either while SQLite happens to be
stable. The test asserts a determinism the query does not provide, and the real fix
is a tie-break: `order_by([m], asc: m.inserted_at, asc: m.id)`. Until then it is a
coin flip on a fast runner, and the production risk the test was written to catch,
the daily crawl flipping a stored mapping between runs, is still live. Reconfirmed
2026-08-29 on PR #615 (`f44cc0b0a`), a single failure in 9797, on a
collections-only diff.

That same test has a second, unrelated mode: a 60s `ExUnit.TimeoutError` whose
stack ends in `Mint.Core.Transport.SSL.recv/3` via Finch, a real outbound HTTPS
call hanging. Do not read one mode as the other. The cause is that the test calls
`Media.create_media_item/2` without `skip_episode_refresh: true`, which its
immediate sibling does pass, so creation triggers an unstubbed metadata fetch
against the network. Any test creating a media item without that flag carries the
same latent dependency. Seen on PR #515.

**Media-detail rail `render_async` timeouts.**
`MediaLive.Show.RecommendationsRailTest` and `MediaLive.Show.FranchiseSectionTest`
fail as `** (RuntimeError) expected async processes to finish within 5000ms`. The
tell is that a different test in the pair fails on each run while `Test` (SQLite)
passes the whole suite on the same commit. These tests warm some caches but the
detail page still makes un-warmed lookups that escape to the live relay, so a slow
relay round trip under CI load blows the budget. SQLite hides it by serializing
(`max_cases: 1`). Observed on PR #536: Postgres passed, then failed twice on
different tests, then passed again on the third re-run, all at effectively the same
tree. Budget three re-runs before suspecting your diff.

Ruling out a real cause is worth one grep. If your diff widened what reads
`Application.get_env(:mydia, :metadata_relay_url)`, note that
`Subtitles.Client.MetadataRelayTest` sets that key to the non-routable
`http://metadata-app.test`. That is safe only because both it and the rail tests
are `async: false`, and ExUnit never runs two sync modules concurrently. Make
either one async and it becomes a genuine cross-test leak with exactly this
timeout symptom.

**`Events.WriterTest`**, "the mailbox bound is soft under concurrent enqueue/2
callers". Fails as `Assertion with < failed, both sides are exactly equal`:
`len < caller_count` with 300 == 300, meaning all 300 concurrent callers landed and
the soft bound dropped nothing. The test's own comment states it relies on "a few
hundred concurrent callers cannot all be scheduled at once", a scheduling
assumption a fast runner can violate outright. Added 2026-08-19 in `f11043a94`. It
presents as a green-SQLite / red-Postgres split only because the Postgres job runs
tests concurrently; it is not adapter-related. Reconfirmed 2026-08-25 on PR #566, a
player-only Dart diff, where it was the single failure in 9182 tests and the re-run
went straight to clean. Third confirmation 2026-08-28 on PR #593, a two-file Elixir
regex diff, a single failure in 9406. That one took two re-runs to go green, and
the first red was a different flake (the silent wasm-plugin exit 1 above). Two reds
in a row on `Test` are not automatically a real failure; compare the signatures.

**`Streaming.AudioTrackSelectorTest`**, where all five `resolved_languages/2` tests
fail together, each asserting a list and getting `[]`, or `nil` from
`Enum.find_index`. `resolved_languages/2` returns `[]` on exactly one branch, when
`configured()` reports `prefer_default_audio_track == true`. `configured()` reads
process-global `Mydia.Config.get()`, so a concurrently scheduled module that sets
that config flips this module's answer wholesale, which is why all five go at once.
Confirmed flaky on PR #488, a player-only Dart diff with zero Elixir.

### SQLite job

**`Downloads.ClientHealthTest`**, `(Exqlite.Error) Database busy`, with
`Ecto.StaleEntryError` and `DBConnection.ConnectionError: owner exited` noise.
Reproduced locally 2026-08-19 in a wider burst: 10 failures in one run, 7 here
(`INSERT INTO download_client_configs`), 2 in `MydiaWeb.Api.HlsControllerTest`
(`INSERT INTO users`, in setup), and `Mydia.Repo.SQLiteWriteContentionTest`'s
IMMEDIATE arm with "database is locked" seven times. The identical tree then ran
clean, and every one of these passes in isolation. It took four 15-minute full runs
to establish that, so do not conclude a repo or config change caused this from one
red run; get a second run on the same tree first. Merely adding a test file shifts
ExUnit's ordering, which is apparently enough to surface it. The root cause is the
fragility PR #502 flagged as its follow-up 3: Oban queues sum to 31 concurrent
workers against `pool_size: 5`, and `Mydia.DataCase` force-disables async on SQLite
purely to dodge this error class. `SQLiteWriteContentionTest` is extra exposed,
with 8 writers against a tmp database with a deliberately short
`busy_timeout: 2_000`.

**`Plugins.SingleFlightTest`**, "acquire/release lets a second waiter in", exits in
`GenServer.stop/3` with `(EXIT) no process`.

**`Jobs.DownloadMonitorTest`**, "pre-completion content rejection". Failed 3 of 4
runs, always the same 3 tests, always with the download classified "missing", but
the sub-symptom varied. Extracting the failing run's ExUnit seed and re-running
locally reproduced it once, then failed to reproduce on an identical second run
with the identical seed, proving genuine timing sensitivity rather than ordering.
Do not repeat that investigation.

### Local-only (`./dev mix precommit`), not CI

**`Indexers.Adapter.ProwlarrTest`**, where
`assert function_exported?(Prowlarr, :search, 3)` returns false when the module is
not yet loaded, so it is purely load-order dependent and passes in isolation every
time. The proper fix is `Code.ensure_loaded?(Prowlarr)` first.

**`Mydia.ReleaseTest`**, "create_backup/0 called twice in the same second", fails
when the two calls straddle a second boundary on a loaded box. The proper fix is
freezing or injecting the clock.

**`render_async` failures are load, and reproducing in isolation does not disprove
that.** `render_async/2` defaults to a 100ms budget.
`ManualSearchQualityGateTest` and `ManualSearchInfoLinkTest` failed and kept
failing when re-run alone, which normally rules out flakiness; the cause was load
average 43 from a concurrent agent plus `./dev mix compile --force`. Check `uptime`
before concluding a `render_async` failure is real, and trust the CI job over a
loaded local box.

## E2E

**`MydiaWeb.Features.AuthTest`** raising `(RuntimeError) invalid session id` from
`Wallaby.HTTPClient`. It hits several unrelated tests in the same run identically,
which is the tell: the ChromeDriver session itself died. Infrastructure, re-run.

**`MydiaWeb.Features.SmokeTest`**, "LiveView JavaScript is loaded", fails alone
(1 of 24) inside `wait_for_liveview()` with `Expected to find 1 visible element
that matched the css '[data-phx-main]', but 0 visible elements were found`. Do not
pattern-match this onto the AuthTest mode; the symptom and the failing test both
differ. Confirmed flaky on PR #488, where the identical SHA failed then passed, and
a master run started eight minutes earlier passed the same job.

**`MydiaWeb.Features.UiHooksTest`**, "PersistedCheckbox a checked box is restored
after navigating away and back", fails alone (1 of 16) with
`(Wallaby.QueryError) Expected to find 1 visible element that matched the css
'#auto-import-toggle', but 0 visible elements were found`. Same shape as the
SmokeTest mode but a different test and selector, on the import-media page
(`lib/mydia_web/live/import_media_live/run_control.ex:73`). The whole
`test/mydia_web/features/ui_hooks_test.exs` file is young and has already needed
one convergence fix (`606737722` added it, `4a653b488` patched it), so treat
selector-not-found failures in it as suspect before blaming a diff.

Confirmed on PR #555 (2026-08-25), again on PR #600 (2026-08-29), and again on PR
PR #615. The #600 run is the useful one, because the diff did touch
`run_control.ex`,
which is exactly when the flake looks causal. Two checks separated it from the
diff: the change to that file was label text only, with the `#auto-import-toggle`
input itself untouched, and the test keys on the CSS id rather than the label. What
decides whether the toggle renders at all is `Settings.list_library_paths/0` plus
`importable?/1` in `import_media_live/index.ex`, neither in the diff. Note
`checkbox_checked?/2` in that test returns `nil` for a missing element instead of
raising, so the first failure surfaces one line later at
`click(Query.css(selector))`; the stacktrace line is not where the element first
went missing.

Three confirmations now, so treat this signature as flake-first. It and the
`Mydia.MediaTest` tie-break can fire in the same run, so two reds on a PR are not
evidence of a real break until you have read both signatures.

## Getting the real output

`gh run view --job <id> --log-failed` returns Postgres server log noise, where
`role "root" does not exist` is normal healthcheck chatter rather than the failure.
Pull the full `--log` and grep for `1) test`. On the UiHooksTest mode,
`--log-failed` piped through a grep for
`^\s*[0-9]+\)|tests?, [0-9]+ failure|Wallaby` did surface it directly, so try the
narrow grep before pulling the full log.

**When both `--log` and `--log-failed` return nothing, it is escape sequences, not
a missing log.** Seen 2026-08-25 on PR #565's `Test / E2E Browser`, where
`gh run view --job <id> --log-failed`, `gh run view --job <id> --log` and
`gh api .../logs` all produced zero bytes, which reads as "no failure detail
available" and invites the wrong conclusion that the job died before logging. `gh
api` alone explains itself, on stderr: `the response contains terminal escape
sequences, pass --allow-escape-sequences to output it anyway`. The two
`gh run view` forms print nothing at all. What works:

```bash
gh api repos/getmydia/mydia/actions/jobs/<job-id>/logs --allow-escape-sequences > /tmp/job.log
grep -aE "^\s+[0-9]+\) test|[0-9]+ tests, [0-9]+ failure" /tmp/job.log
```

Use `grep -a`, since the file is then full of control bytes and grep otherwise
treats it as binary and prints only "Binary file matches". Getting the per-error
breakdown out of a multi-failure run is worth one extra pass:

```bash
grep -aoE "\*\* \([A-Za-z.]+Error\)[^\"]{0,80}" /tmp/job.log | sed 's/^[0-9T:.-]*Z *//' | sort | uniq -c | sort -rn
```

On that PR it collapsed 20 failures into 2 real causes plus known cascade noise in
one step.
