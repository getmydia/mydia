# rqbit Observed Upload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep an upload total for rqbit torrents that survives pauses and restarts, feed it to the ratio everywhere, and show the uploaded amount on Downloads rows (finishes #1436).

**Architecture:** A new `Mydia.Downloads.ObservedUpload`, a sibling of `Mydia.Downloads.ObservedSeedTime`, banks rqbit's session-only `uploaded_bytes` into `Download.metadata["observed_upload"]` on each `DownloadMonitor` pass. A read-time overlay replaces `uploaded` and `ratio` on enriched rows and on the status `ClientRemoval` judges. Adapters opt in with `DownloadStatus.uploaded_session_only?`.

**Tech Stack:** Elixir, Ecto (SQLite and PostgreSQL), Phoenix LiveView, Bypass.

**Spec:** `design/specs/2026-11-20-rqbit-observed-upload-design.md`

## Global Constraints

- Metadata key `"observed_upload"`, entry `%{"bytes" => non_neg_integer, "session" => non_neg_integer}`. No migration.
- Step rules: no entry or malformed: `bytes = live, session = live`; `live >= session`: `bytes += live - session`; `live < session`: `bytes += live`. Always `session = live`.
- Only rows with `uploaded_session_only? == true`, `in_client? == true` and `status_as_of == nil` are recorded or overlaid.
- `record/2` steps from `live_uploaded` (the raw client counter), never from the overlaid `uploaded`.
- Writes: same transaction and `update_all` as `ObservedSeedTime.write/3`; write only when the entry changed; a failing row is logged and returned unchanged.
- UI element id `download-uploaded-<id>`, title `gettext("Uploaded")`, icon `hero-arrow-up-circle`, `format_file_size/1`; placed right after the upload speed on queue and completed rows; absent when `in_client?` is false.
- The "Seeding goal met" chip is unchanged.
- No em dashes in prose, docs or commit messages. Commits via `direnv exec . git commit -F <msgfile>`; verify each with `git show --stat HEAD`.

## Review Focus

- rqbit reads 0 for a paused torrent: the banked total and its ratio must hold (Task 1 `step` reset-to-0 test, Task 3 record test).
- A stale snapshot row (`status_as_of` set) must neither step nor be overlaid with a stepped value (Task 3 skip test).
- A torrent with `size` 0 or nil (magnet before metadata): ratio left as the client's, no crash (Task 1 overlay test).
- Double counting: an already-overlaid row recorded twice with the same live counter must not grow `bytes` (Task 3 idempotence test).
- A malformed entry (`"bytes" => "x"`) or nil `metadata`: treated as no entry, no crash (Task 1 tests).

---

### Task 1: `ObservedUpload` core and struct fields

**Files:**
- Create: `lib/mydia/downloads/observed_upload.ex`
- Modify: `lib/mydia/downloads/structs/download_status.ex` (defstruct, `@type t`)
- Modify: `lib/mydia/downloads/structs/enriched_download.ex` (defstruct, `@type t`)
- Test: `test/mydia/downloads/observed_upload_test.exs`

**Interfaces:**
- Produces:
  - `DownloadStatus` field `uploaded_session_only?: false` (boolean, commented as in the spec's "Adapter signal").
  - `EnrichedDownload` fields `uploaded_session_only?: false` and `live_uploaded` (integer or nil, the client's raw counter).
  - `ObservedUpload.step(entry :: map() | nil, live :: non_neg_integer()) :: map()`
  - `ObservedUpload.total(entry :: map() | nil, live :: non_neg_integer()) :: non_neg_integer()`
  - `ObservedUpload.entry(metadata :: map() | nil) :: map() | nil` (the stored entry when well-formed, else nil)
  - `ObservedUpload.overlay(row :: map()) :: map()`: for a row with `uploaded_session_only?: true`, `in_client?: true`, nil `status_as_of`, sets `uploaded = total(entry(row.metadata), row.live_uploaded)` and `ratio = uploaded / size` when `size` is a positive integer; any other row is returned unchanged.
  - `ObservedUpload.overlay_status(status :: DownloadStatus.t(), metadata :: map() | nil) :: DownloadStatus.t()`: the same for a flagged status, live counter `status.uploaded`.

- [ ] **Step 1: Write the failing tests** (`use ExUnit.Case, async: true`)

```elixir
describe "step/2" do
  test "first sight counts the current session in full" do
    assert ObservedUpload.step(nil, 500) == %{"bytes" => 500, "session" => 500}
  end

  test "adds growth within a session" do
    assert ObservedUpload.step(%{"bytes" => 500, "session" => 500}, 800) ==
             %{"bytes" => 800, "session" => 800}
  end

  test "a lower counter is a new session and adds in full" do
    assert ObservedUpload.step(%{"bytes" => 800, "session" => 800}, 100) ==
             %{"bytes" => 900, "session" => 100}
  end

  test "a reset to 0 while paused keeps the total" do
    assert ObservedUpload.step(%{"bytes" => 800, "session" => 800}, 0) ==
             %{"bytes" => 800, "session" => 0}
  end

  test "a malformed entry is treated as none" do
    assert ObservedUpload.step(%{"bytes" => "x"}, 50) == %{"bytes" => 50, "session" => 50}
  end
end

test "total/2 agrees with step/2" do
  entry = %{"bytes" => 800, "session" => 800}
  for live <- [0, 100, 800, 1200], do: assert ObservedUpload.total(entry, live) == ObservedUpload.step(entry, live)["bytes"]
end

describe "overlay/1" do
  # base: %{uploaded_session_only?: true, in_client?: true, status_as_of: nil,
  #         live_uploaded: 0, uploaded: 0, ratio: 0.0, size: 1000,
  #         metadata: %{"observed_upload" => %{"bytes" => 2000, "session" => 2000}}}
  test "a paused rqbit row keeps the banked total and ratio" # uploaded == 2000, ratio == 2.0
  test "an unflagged row is unchanged"                       # uploaded_session_only?: false
  test "a stale or not-in-client row is unchanged"           # status_as_of set; in_client?: false
  test "size 0 or nil leaves the ratio as reported"          # uploaded == 2000, ratio == 0.0
  test "nil metadata uses the live counter"                  # metadata: nil, live 300 -> uploaded 300
end

test "overlay_status/2 applies to a flagged DownloadStatus" do
  status = DownloadStatus.new(%{id: "h", name: "n", state: :paused, progress: 100.0,
    uploaded: 0, ratio: 0.0, size: 1000, uploaded_session_only?: true})
  meta = %{"observed_upload" => %{"bytes" => 1500, "session" => 1500}}
  assert %{uploaded: 1500, ratio: 1.5} = ObservedUpload.overlay_status(status, meta)
  assert ObservedUpload.overlay_status(%{status | uploaded_session_only?: false}, meta).ratio == 0.0
end
```

Write the five `overlay/1` tests out with the asserted values in the comments.

- [ ] **Step 2: Run** `./dev mix test test/mydia/downloads/observed_upload_test.exs`. Expected: FAIL, `ObservedUpload` undefined.

- [ ] **Step 3: Implement** the struct fields and the module. Moduledoc in the voice of `ObservedSeedTime`'s: session-only counters, the entry shape, the step table, first sight in full, the between-passes undercount. `entry/1` accepts only a map whose `"bytes"` and `"session"` are non-negative integers.

- [ ] **Step 4: Run** the same command. Expected: PASS.

- [ ] **Step 5: Commit** `feat(downloads): add ObservedUpload, an upload total that survives pauses`.

---

### Task 2: rqbit flag and enrichment overlay

**Files:**
- Modify: `lib/mydia/downloads/client/rqbit.ex` (`build_status/2`)
- Modify: `lib/mydia/downloads/history.ex` (`enrich_download_with_torrent_status/2`)
- Test: `test/mydia/downloads/client/rqbit_test.exs` (describe "get_status/2 state mapping (Bypass)")
- Test: `test/mydia/downloads/history_observed_upload_test.exs` (new)

**Interfaces:**
- Consumes: Task 1 fields, `ObservedUpload.overlay/1`.
- Produces: every in-client enriched row carries `live_uploaded` (raw `torrent_status.uploaded`) and `uploaded_session_only?` (copied from the status, default false); flagged rows arrive overlaid.

- [ ] **Step 1: Write the failing tests**
  - rqbit_test: `test "marks the upload counter as session-only"`; an existing Bypass status fixture, assert `status.uploaded_session_only? == true`.
  - history_observed_upload_test (`Mydia.DataCase, async: false`): register a list adapter under `:rqbit` the way `test/mydia_web/live/downloads_live/seeding_goal_test.exs` registers `ListAdapter` under `:qbittorrent` (restore the original in `on_exit`). Use a client config of type `"rqbit"` and a download whose metadata holds `%{"observed_upload" => %{"bytes" => 2000, "session" => 2000}}`. The adapter returns a status with `state: :paused, uploaded: 0, ratio: 0.0, size: 1000, uploaded_session_only?: true`.
    - `test "a paused rqbit torrent reads its banked total"`: `[row] = Downloads.list_downloads_with_status(filter: :all)`; assert `row.uploaded == 2000`, `row.ratio == 2.0`, `row.live_uploaded == 0`.
    - `test "an unflagged client's counter is shown as reported"`: the same with `uploaded_session_only?: false`; assert `row.uploaded == 0`.

- [ ] **Step 2: Run** both files. Expected: FAIL.

- [ ] **Step 3: Implement**: `uploaded_session_only?: true` in `build_status/2`, plus a comment citing rqbit 9.0.1's per-session `uploaded_bytes`. In enrichment, add `live_uploaded: torrent_status.uploaded`, `uploaded_session_only?: torrent_status.uploaded_session_only? == true`, and pipe the built struct through `ObservedUpload.overlay/1`.

- [ ] **Step 4: Run** both files, plus `test/mydia/downloads/history_*` and `test/mydia/downloads/client/rqbit_test.exs`. Expected: PASS.

- [ ] **Step 5: Commit** `feat(downloads): read rqbit's ratio from the kept upload total`.

---

### Task 3: record each monitor pass

**Files:**
- Modify: `lib/mydia/downloads/observed_upload.ex` (add `record/2`)
- Modify: `lib/mydia/jobs/download_monitor.ex` (call after `ObservedSeedTime.record/2`; extend the moduledoc line at 16)
- Test: `test/mydia/downloads/observed_upload_record_test.exs` (new, `Mydia.DataCase, async: false`)

**Interfaces:**
- Consumes: Task 1 `step/2`, `entry/1`, `overlay/1`; Task 2 row fields.
- Produces: `ObservedUpload.record(rows :: [map()], now :: DateTime.t()) :: [map()]`. `now` is unused today but kept for parity with `ObservedSeedTime.record/2` and the monitor call site. Each recorded row is returned with its new entry in `metadata` and re-overlaid.

- [ ] **Step 1: Write the failing tests.** Rows are `EnrichedDownload` structs over real `download_fixture/1` rows, built as in `test/mydia/downloads/observed_seed_time_test.exs`.
  - `test "banks the live counter and returns the row overlaid"`: live 300, no entry. DB entry becomes `%{"bytes" => 300, "session" => 300}`; the returned row has `uploaded == 300`.
  - `test "a pause after uploading keeps the total"`: entry `{1000, 1000}`, live 0, size 500. DB `{1000, 0}`; the returned row has `ratio == 2.0`.
  - `test "recording an overlaid row twice does not double count"`: run `record` on the result of `record`, same `live_uploaded`. The DB `bytes` is unchanged.
  - `test "skips unflagged, stale and not-in-client rows"`: no `"observed_upload"` key is written for any of them.
  - `test "writes nothing when the entry is unchanged"`: assert `updated_at` and the other metadata keys are unchanged (seed `"observed_seeding"` alongside and assert it survives).
  - `test "one failing row does not stop the others"`: a row whose id is not in the DB, beside a good row. The good row is written and the call returns both.

- [ ] **Step 2: Run** `./dev mix test test/mydia/downloads/observed_upload_record_test.exs`. Expected: FAIL.

- [ ] **Step 3: Implement** `record/2` by mirroring `ObservedSeedTime.record/2`, `record_row/2`, `write/3`, `locked_row/1` and `step_row/3`. Step from `row.live_uploaded`. Tracked rows are those `overlay/1` would change. The rescue logs `"Recording observed upload failed; the poll continues"`. In the monitor: `downloads = Mydia.Downloads.ObservedUpload.record(downloads, now)` on the line after the seed-time record.

- [ ] **Step 4: Run** the new file and `test/mydia/jobs/download_monitor*` and `test/mydia/downloads/built_in/`. Expected: PASS.

- [ ] **Step 5: Commit** `feat(downloads): bank rqbit's upload counter on each monitor pass`.

---

### Task 4: ClientRemoval judges the kept total

**Files:**
- Modify: `lib/mydia/downloads/client_removal.ex` (`terms_met?/2`)
- Test: `test/mydia/downloads/client_removal_test.exs` (describe "seeding guard")

**Interfaces:**
- Consumes: `ObservedUpload.overlay_status/2`.

- [ ] **Step 1: Write the failing test** `test "a paused rqbit torrent is judged on its banked ratio"`. Download metadata: `tracker_terms` `%{"minimum_ratio" => 1.0}` and `"observed_upload" => %{"bytes" => 2000, "session" => 2000}`. Status: `%{status(:paused, "x") | uploaded: 0, ratio: 0.0, size: 1000, uploaded_session_only?: true}`. Assert `ClientRemoval.terms_met?(download, status)`. Assert `refute` for the same status with `uploaded_session_only?: false`.

- [ ] **Step 2: Run** `./dev mix test test/mydia/downloads/client_removal_test.exs`. Expected: the new test FAILS.

- [ ] **Step 3: Implement**: in the `%DownloadStatus{}` branch, rebind `status = ObservedUpload.overlay_status(status, download.metadata)` first.

- [ ] **Step 4: Run** the file. Expected: PASS.

- [ ] **Step 5: Commit** `fix(downloads): judge rqbit seeding goals on the kept upload total`.

---

### Task 5: Uploaded metric on Downloads rows

**Files:**
- Modify: `lib/mydia_web/live/downloads_live/index.html.heex` (queue block after `download-upload-*`, completed block after `download-upload-*`)
- Modify: `priv/gettext/default.pot` and locale `.po` files via `./dev mix gettext.extract --merge`
- Test: `test/mydia_web/live/downloads_live/seeding_goal_test.exs`

- [ ] **Step 1: Write the failing tests** next to the existing `download-upload-*` assertions (line ~180):
  - `test "shows the uploaded amount on seeding and downloading rows"`: statuses with `uploaded: 2048`. Assert `has_element?(view, "#download-uploaded-#{seeding.id}", "2.0 KB")` and the same for the downloading row.
  - `test "omits the uploaded amount for a row not in the client"`: a download whose hash the adapter does not list. `refute has_element?(view, "#download-uploaded-#{id}")`.

  Check that `format_file_size(2048)` renders "2.0 KB", the way `format_speed` renders "2.0 KB/s" here; adjust the literal if not.

- [ ] **Step 2: Run** `./dev mix test test/mydia_web/live/downloads_live/seeding_goal_test.exs`. Expected: FAIL.

- [ ] **Step 3: Implement** the span from Global Constraints, `:if={download.in_client?}`, `class="inline-flex items-center gap-1 tabular-nums"`, in both blocks. Then run `./dev mix gettext.extract --merge`.

- [ ] **Step 4: Run** the file and `test/mydia_web/live/downloads_live/`. Expected: PASS.

- [ ] **Step 5: Commit** `feat(downloads): show the uploaded amount beside upload speed and ratio`.

---

### Task 6: Docs, full check, PR

**Files:**
- Modify: `lib/mydia/downloads/README.md` (after the `observed_seeding` paragraph near line 67)

- [ ] **Step 1:** Write the README paragraph: rqbit's per-session counter, the `"observed_upload"` key and step rules, overlay on read (enrichment and `ClientRemoval`), the undercount when a pause or restart falls between passes, and why first sight counts in full.
- [ ] **Step 2:** Run `./dev mix precommit` (in foreground chunks if it nears the 600s cap). Expected: format, credo, gettext, size ratchet and tests clean. Fix anything that is ours.
- [ ] **Step 3: Commit** `docs(downloads): document the observed upload total`.
- [ ] **Step 4:** `git log --oneline origin/master..HEAD` lists the spec, plan and Tasks 1-6 commits only; `git diff --stat origin/master...` names no file outside this plan.
- [ ] **Step 5:** Push `HEAD:feat/rqbit-observed-upload` and open a PR whose body says `Closes #1436`. Babysit: CI and CodeRabbit, no auto-merge, merge by hand once green. Confirm that #1436 closed.
