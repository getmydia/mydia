# EDL Commercial Skipping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read sidecar `.edl` files into `media_segments` as commercial breaks and auto-skip them in the player.

**Architecture:** A pure parser (`Mydia.Library.Edl`) and a reconciler (`Mydia.Library.EdlSidecars`) run by the library scanner write `type: "commercial", source: "edl"` rows. GraphQL `SegmentType` gains `COMMERCIAL`. The player maps it (and Plex/Jellyfin commercials) to `SegmentType.commercial` and auto-skips it under a new setting that defaults to on.

**Tech Stack:** Elixir/Ecto (SQLite + PostgreSQL), Absinthe, Rust `async-graphql` parity crate, Flutter/Riverpod.

**Spec:** `design/specs/2026-11-17-edl-commercial-skip-design.md`

## Global Constraints

- Segment type string: `"commercial"`. Source string: `"edl"`. EDL rows store `confidence: 1.0`.
- Kept EDL actions: `0` and `3`. Two-field lines count as `0`. Everything else is dropped.
- The unique index keeps the name `media_segments_media_file_id_type_index`, columns `[:media_file_id, :type]`, `WHERE type IN ('intro', 'credits')`.
- Migration file: `priv/repo/migrations/20261117153412_partial_unique_media_segments_type.exs` (no collision on any remote branch as of writing; re-run the CLAUDE.md collision check before committing).
- Player setting key: `auto_skip_commercials`, default **true** when unset.
- Player label key: `segmentSkipCommercial`, English `"Skip Ad"`.
- Nothing reads or writes the `.edl` file except `Storage.ls/1` and `Storage.read_path/1`.
- No real movie/TV titles in tests or fixtures; invent them. No em dashes in prose.
- Commit from the worktree with `direnv exec . git commit ...`, one commit per step, then `git show --stat HEAD`.
- Elixir tests: `./dev mix test <paths>`. Player tests: `./dev flutter test --concurrency=1 <paths>` (without the flag files are silently skipped).

## Review Focus

1. **A season re-detection wiping EDL rows.** `SegmentDetection.reset_season/2` must leave `source: "edl"` rows. Test in Task 1.
2. **Comskip's real output shape**: tab-separated, `\r\n` line endings, a trailing blank line, a leading `0.00` start. Test in Task 2.
3. **A transient read failure (S3 timeout, permissions) deleting known breaks.** A failed `read_path` must keep existing rows. Test in Task 3.
4. **Two videos in one directory** (`A.mkv`, `A.extended.mkv`, one `A.edl`): the sidecar belongs only to the file whose basename matches exactly. Test in Task 3.
5. **Intro auto-skip off (the default) silently disabling commercial auto-skip**, or vice versa. Test in Task 6.

---

### Task 1: Schema: commercial type, edl source, partial unique index, detection scoping

**Files:**
- Modify: `lib/mydia/library/media_segment.ex` (`@types`, `@sources`)
- Create: `priv/repo/migrations/20261117153412_partial_unique_media_segments_type.exs`
- Modify: `lib/mydia/library/segment_detection.ex:198` (`reset_season/2` delete)
- Test: `test/mydia/library/media_segment_test.exs`, `test/mydia/library/segment_detection_test.exs`

**Interfaces:**
- Produces: `MediaSegment.types/0 == ~w(intro credits commercial)`, `MediaSegment.sources/0 == ~w(chapters fingerprint edl)`. Multiple `commercial` rows per file are insertable.

- [ ] **Step 1: Write failing tests** in `media_segment_test.exs`:
  - `"accepts a commercial segment from an edl source"`: changeset with `type: "commercial", source: "edl", confidence: 1.0` is valid.
  - `"allows several commercial segments on one file"`: insert two commercial rows (`0..30_000`, `600_000..720_000`) on one media file; both `{:ok, _}`.
  - `"still allows only one intro per file"`: second `intro` insert on the same file returns `{:error, changeset}` with an error on `:media_file_id` or `:type` from the unique constraint.

  In `segment_detection_test.exs`: `"reset_season/2 keeps edl segments"`: an episode file with one `intro` (source `chapters`) and one `commercial` (source `edl`); after `reset_season/2` only the commercial row remains.
- [ ] **Step 2: Run** `./dev mix test test/mydia/library/media_segment_test.exs test/mydia/library/segment_detection_test.exs`. Expected: the new tests FAIL (inclusion validation, unique index).
- [ ] **Step 3: Implement.** Add the type and source. Migration with `up/0` dropping `index(:media_segments, [:media_file_id, :type])` and creating `unique_index(:media_segments, [:media_file_id, :type], name: :media_segments_media_file_id_type_index, where: "type IN ('intro', 'credits')")`; `down/0` restores the plain unique index after deleting `commercial` rows. Add `and s.source in ["chapters", "fingerprint"]` to the `reset_season/2` delete; update its `@doc` to say EDL rows are kept.
- [ ] **Step 4: Run** the same command, plus with `DATABASE_TYPE=postgres` per `test/README.md`. Expected: PASS on both adapters.
- [ ] **Step 5: Commit** `feat(library): allow many commercial segments per file`.

### Task 2: EDL parser

**Files:**
- Create: `lib/mydia/library/edl.ex`
- Test: `test/mydia/library/edl_test.exs`

**Interfaces:**
- Produces: `Mydia.Library.Edl.parse(binary()) :: [{non_neg_integer(), pos_integer()}]` (ms, sorted by start, merged, never raises).

- [ ] **Step 1: Write failing tests** (`async: true`):
  - Comskip output `"0.00\t25.03\t0\r\n612.48\t735.10\t3\r\n\r\n"` → `[{0, 25_030}, {612_480, 735_100}]`.
  - Timestamps `"00:10:12.500 00:12:00 3\n"` → `[{612_500, 720_000}]`; `"10:12.5 12:00 0"` → `[{612_500, 720_000}]`.
  - Two-field line `"5 10"` → `[{5_000, 10_000}]`.
  - Actions `1`, `2`, `7` dropped: `"5 10 1\n20 30 2\n40 50 7"` → `[]`.
  - Frame lines `"#100 #200 0"` dropped → `[]`.
  - Garbage `"hello\n5 x 0\n"` → `[]`; `""` → `[]`.
  - Reversed and zero-length `"10 5 0\n7 7 0"` → `[]`.
  - Overlap and touching merged, input unsorted: `"50 60 0\n10 20 0\n15 30 3\n30 40 0"` → `[{10_000, 40_000}, {50_000, 60_000}]`.
- [ ] **Step 2: Run** `./dev mix test test/mydia/library/edl_test.exs`. Expected: FAIL, module undefined.
- [ ] **Step 3: Implement** `parse/1`: split lines on `~r/\r?\n/`, fields on whitespace, parse each time with `Float.parse/1` on a bare number or by splitting on `:` (1 to 3 parts, last part a float); round to integer ms. Any field failing to parse drops the line. Moduledoc names the format (mplayer/Kodi EDL) and why mute and scene markers are dropped.
- [ ] **Step 4: Run** the test. Expected: PASS.
- [ ] **Step 5: Commit** `feat(library): parse EDL commercial breaks`.

### Task 3: Sidecar reconciler and scanner hook

**Files:**
- Create: `lib/mydia/library/edl_sidecars.ex`
- Modify: `lib/mydia/subtitles/sidecars.ex:350-357` (make `dir_for/1` and `basename_for/1` public with `@doc`, reuse them; do not copy)
- Modify: `lib/mydia/jobs/library_scanner.ex:262-264` and add a `reconcile_edl_sidecars/1` private beside `reconcile_sidecars/1`
- Test: `test/mydia/library/edl_sidecars_test.exs`, `test/mydia/library/edl_sidecars_s3_test.exs` (`@moduletag :s3`, setup copied from `test/mydia/subtitles/sidecars_s3_test.exs`)

**Interfaces:**
- Consumes: `Edl.parse/1`; `Sidecars.dir_for/1`, `Sidecars.basename_for/1`; `Storage.ls/1`, `Storage.read_path/1`.
- Produces: `Mydia.Library.EdlSidecars.reconcile_all([MediaFile.t()]) :: %{adopted: n, updated: n, reaped: n, errors: [{path, reason}]}`. `adopted` = file had no edl rows and now has some; `updated` = rows replaced; `reaped` = rows deleted because the sidecar is gone.

- [ ] **Step 1: Write failing tests** (local library in a tmp dir, files written with `File.write!/2`, media files via `Mydia.MediaFixtures`):
  - adopts: `Invented Show S01E01.mkv` + `Invented Show S01E01.edl` → two `commercial`/`edl` rows, `confidence == 1.0`, tally `adopted: 1`.
  - unchanged second pass writes nothing: row ids and `updated_at` unchanged, tally all zero.
  - changed `.edl` replaces rows, tally `updated: 1`.
  - removed `.edl` deletes rows, tally `reaped: 1`; intro rows on the same file untouched.
  - extension matched case-insensitively (`.EDL`).
  - two videos in one dir (`Invented Film.mkv`, `Invented Film.extended.mkv`, only `Invented Film.edl`): only the first gets rows.
  - read error keeps rows: existing edl rows, `.edl` present but `chmod 000`, rows still there and `errors` non-empty.
  - an `.edl` that parses to `[]` deletes existing rows and inserts none.
  - S3 file: `S3Helpers.put_object!` the `.edl` beside the video; rows adopted.
- [ ] **Step 2: Run** `./dev mix test test/mydia/library/edl_sidecars_test.exs`. Expected: FAIL, module undefined.
- [ ] **Step 3: Implement** `reconcile_all/1`: group by `Sidecars.dir_for/1`, `Storage.ls/1` once per dir (an `ls` error records `{dir, reason}` and skips the dir). Per file, find the entry equal to `basename <> ".edl"` case-insensitively. Compare parsed ranges with existing `{start_ms, end_ms}` of the file's `edl` rows; on difference, one `Repo.transaction` deletes them and `insert_all`s the new rows (with `inserted_at`/`updated_at` set). Never touches rows with another source.
- [ ] **Step 4: Run** the tests (S3 file with the s3 tag included per `test/README.md`). Expected: PASS.
- [ ] **Step 5: Hook into the scanner.** After `reconcile_sidecars(library_path)` call `reconcile_edl_sidecars(library_path)`, same condition, same `rescue` contract, logging `"EDL sidecars reconciled"` with the tally when anything changed. Add a scanner test: a scan of a library containing a video and its `.edl` leaves commercial rows. Run `./dev mix test test/mydia/jobs/library_scanner_test.exs test/mydia/subtitles`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(library): adopt sidecar EDL files as commercial segments`.

### Task 4: GraphQL `COMMERCIAL` and Rust parity

**Files:**
- Modify: `lib/mydia_web/schema/enum_types.ex:87-90`
- Modify: `priv/graphql/schema.graphql` (regenerated)
- Modify: `server/crates/api/src/types/common.rs:150-153`
- Test: `test/mydia_web/schema/media_segment_test.exs`

**Interfaces:**
- Produces: GraphQL `SegmentType.COMMERCIAL`; `segments { type }` returns `"COMMERCIAL"` for an edl row.

- [ ] **Step 1: Write failing test** `"returns commercial segments"` in `media_segment_test.exs`, using `@movie_segments_query`: a movie file with a `commercial`/`edl` row (`600_000..720_000`) returns `%{"type" => "COMMERCIAL", "startMs" => 600_000, "endMs" => 720_000}`.
- [ ] **Step 2: Run** `./dev mix test test/mydia_web/schema/media_segment_test.exs`. Expected: FAIL (enum serialization error).
- [ ] **Step 3: Implement.** Add `value(:commercial, description: "Commercial break, from an EDL sidecar")`. Run `./dev mix schema.export`. Add `Commercial` to the Rust `SegmentType`.
- [ ] **Step 4: Run** `./dev mix test test/mydia_web/schema/media_segment_test.exs test/mydia_web/schema_sdl_test.exs` and `cd server && cargo test -p mydia_api --test sdl_parity --test types_common` (inside the devenv shell). Expected: PASS.
- [ ] **Step 5: Commit** `feat(graphql): expose commercial segments`.

### Task 5: Player model, Plex/Jellyfin mapping, "Skip Ad" label

**Files:**
- Modify: `player/lib/domain/models/media_segment.dart` (`SegmentType`, `_parseType`)
- Modify: `player/lib/core/sources/plex/plex_mapping.dart:242`, `player/lib/core/sources/jellyfin/jellyfin_mapping.dart:287`
- Modify: `player/lib/l10n/formatters.dart:597-601`, `player/lib/l10n/app_{en,es,pt,pt_BR}.arb`
- Test: `player/test/presentation/widgets/video_controls/skip_segment_button_test.dart`, `player/test/core/sources/plex/plex_mapping_test.dart`, `player/test/core/sources/jellyfin/jellyfin_mapping_test.dart`

**Interfaces:**
- Produces: `SegmentType.commercial`; `context.l10n.segmentSkipLabel(SegmentType.commercial) == "Skip Ad"` in English.

- [ ] **Step 1: Write failing tests:**
  - `MediaSegment.fromJson({'type': 'COMMERCIAL', 'startMs': 1, 'endMs': 2}).type == SegmentType.commercial`, and `actionable` is true.
  - Plex marker `{'type': 'commercial', 'startTimeOffset': 1000, 'endTimeOffset': 2000}` → one `commercial` segment.
  - Jellyfin body `{'Items': [{'Type': 'Commercial', 'StartTicks': 10000000, 'EndTicks': 20000000}]}` → one `commercial` segment `1000..2000` ms.
  - `SkipSegmentButton` with a commercial segment at a covered position shows text `"Skip Ad"`.
- [ ] **Step 2: Run** `./dev flutter test --concurrency=1` on those files. Expected: FAIL.
- [ ] **Step 3: Implement.** Add the enum value and parse cases, the two mapping cases, the `formatters.dart` switch arm, and `segmentSkipCommercial` to all four `.arb` files with an `@` description (es `"Saltar anuncio"`, pt and pt_BR `"Pular anúncio"`). Regenerate localizations with `./dev flutter gen-l10n`.
- [ ] **Step 4: Run** the same tests. Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): recognise commercial segments`.

### Task 6: Per-type auto-skip and the commercials setting

**Files:**
- Modify: `player/lib/presentation/screens/player/segment_skipper.dart`
- Modify: `player/lib/core/settings/settings_service.dart` (key, getter, setter, reset list near line 235)
- Modify: `player/lib/domain/models/user_settings.dart`, `player/lib/presentation/screens/settings/settings_controller.dart`, `player/lib/presentation/screens/settings/widgets/settings_sections.dart:78-88`
- Modify: `player/lib/presentation/screens/player/player_screen.dart:1440-1452` (`_loadAutoSkipPreference`)
- Modify: `player/lib/core/backup/backup_snapshot.dart:28-35`
- Modify: `player/lib/l10n/app_*.arb` (`settingsAutoSkipCommercialsTitle` "Skip commercials", `settingsAutoSkipCommercialsSubtitle` "Off shows a skip button instead")
- Test: `player/test/presentation/screens/player/segment_skipper_test.dart`, `player/test/domain/models/user_settings_test.dart`, `player/test/core/backup/backup_snapshot_test.dart`, a settings service test beside the existing one for `auto_skip_segments`

**Interfaces:**
- Consumes: `SegmentType.commercial` (Task 5).
- Produces: `SegmentSkipper.autoSkipIntroCredits` (bool, default false) and `SegmentSkipper.autoSkipCommercials` (bool, default true) replacing `autoSkip`; `SettingsService.getAutoSkipCommercials() -> Future<bool>`, `setAutoSkipCommercials(bool)`; `UserSettings.autoSkipCommercials`; `SettingsController.setAutoSkipCommercials(bool)`.

- [ ] **Step 1: Write failing tests** in `segment_skipper_test.dart` (rewrite existing uses of `autoSkip` to `autoSkipIntroCredits`):
  - defaults: a fresh skipper with an intro (`0..30s`) and a commercial (`600..720s`); `maybeAutoSkip` at 5s does not seek, at 601s seeks to 720s.
  - flipped (`autoSkipIntroCredits = true`, `autoSkipCommercials = false`): seeks at 5s to 30s, not at 601s.
  - seeking back into a spent break: second call at 650s after the first skip does not seek.
  - two distinct breaks each skip once.

  Settings: `getAutoSkipCommercials()` returns `true` with nothing stored and `false` after `setAutoSkipCommercials(false)`. Backup: `kBackupSettingKeys` contains `'auto_skip_commercials'`.
- [ ] **Step 2: Run** `./dev flutter test --concurrency=1` on those files. Expected: FAIL.
- [ ] **Step 3: Implement.** `maybeAutoSkip` passes `takeAutoSkip` only the segments whose type is enabled (`commercial` → `autoSkipCommercials`, `intro`/`credits` → `autoSkipIntroCredits`). Getter returns `value != 'false'`. `_loadAutoSkipPreference` reads both settings and sets both fields; its failure default leaves the field defaults. Settings row key `auto-skip-commercials-switch`, icon `Icons.fast_forward`, shown after the existing auto-skip row, `value: current?.autoSkipCommercials ?? true`. Add the key to `kBackupSettingKeys` and to the reset list.
- [ ] **Step 4: Run** the step 2 tests plus `player/test/presentation/screens/player/player_screen_cast_skip_segments_test.dart` and `player_screen_segments_isolation_test.dart`. Expected: PASS.
- [ ] **Step 5: Run** `./dev player test` for the full suite and `./dev mix precommit`. Expected: green; the test count is not materially below the last full run.
- [ ] **Step 6: Commit** `feat(player): auto-skip commercial breaks by default`.
