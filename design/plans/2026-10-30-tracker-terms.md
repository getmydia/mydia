# Tracker terms Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every indexer adapter reports a tracker's terms (private flag, minimum
ratio, minimum seed time, volume factors), operators can override them per
tracker in layered config, and the effective terms are frozen on the
`Download` at grab.

**Architecture:** A `TrackerTerms` struct rides on `SearchResult.terms`. Each
adapter fills it from what its protocol carries. Overrides live in a
`tracker_rules` list (YAML and env through `Mydia.Config.Schema`, DB rows in a
new `tracker_rule_configs` table that shadow a runtime entry with the same
tracker, the path-mappings pattern). `Mydia.Indexers.TrackerRules` resolves
effective terms; the grab metadata builder freezes them. A small
`tracker_sightings` table, fed by a buffered recorder from `search_all/2`,
backs the admin list of recently seen trackers and the stale-override flag.

**Tech Stack:** Elixir, Ecto (SQLite and PostgreSQL), Phoenix LiveView,
daisyUI admin components, SweetXml, Req, Bypass.

Spec: `design/specs/2026-10-30-private-trackers-roadmap-design.md`, "Spec 0".

## Global Constraints

- Every `TrackerTerms` field may be nil, meaning unknown.
- `minimum_seed_time` is in seconds on the struct and in frozen metadata.
- Precedence per field: override, then the tracker's value for that release, then nil.
- Tracker match is case-insensitive against `SearchResult.indexer`.
- No migration for download terms: `Download.metadata["tracker_terms"]`.
- Migration columns are `:text`, never `:string`; real timestamp filename.
- Every user-visible string goes through gettext; no em dashes; fictional tracker names only.
- Spec 4 adds `grab_limit` and `query_limit` to the same rule entry, so the rule
  struct, table and changeset must take new optional fields without reshaping.

## Deviations from the spec found while planning

- Prowlarr's `/api/v1/search` JSON has no `minimumRatio`, `minimumSeedTime`,
  `downloadVolumeFactor` or `uploadVolumeFactor` (`ReleaseResource.cs` on
  Prowlarr `develop`). It carries `indexerFlags` (`freeleech`, `halfleech`,
  `neutralleech`, `doubleupload`, ...), which Prowlarr derives from the volume
  factors. The adapter maps the flags back to factors, reads the four camelCase
  keys too in case a future Prowlarr adds them, and takes privacy from
  `GET /api/v1/indexer` (`privacy`: `public`, `private`, `semiPrivate`), cached
  per connection for an hour.
- Jackett's Torznab items do not say whether the tracker is private, so
  `private?` stays nil there (an override supplies it).
- Parity tooling keeps reading volume factors from `metadata` for now; moving it
  to `terms` would start counting native/WASM differences the ratchet has never
  seen and belongs with Spec 3.

## File structure

| File | Responsibility |
| --- | --- |
| `lib/mydia/indexers/structs/tracker_terms.ex` (new) | Struct, `from_torznab/1`, `from_map/1`, `to_map/1`, `empty?/1`, number parsing |
| `lib/mydia/indexers/search_result.ex` | `terms` field |
| `lib/mydia/indexers/adapter/{prowlarr,jackett,newznab}.ex` | Fill terms |
| `lib/mydia/indexers/cardigann/result/{context,transform}.ex`, `cardigann_result_parser.ex` | Built-in engine terms |
| `lib/mydia/indexers/cardigann/wasm/codec.ex` | WASM engine terms |
| `lib/mydia/config/schema.ex`, `lib/mydia/config/schema/tracker_rule_changeset.ex` (new), `lib/mydia/config/loader.ex` | `tracker_rules` YAML/env |
| `priv/repo/migrations/<ts>_create_tracker_rule_configs_and_sightings.exs` (new) | Both tables |
| `lib/mydia/settings/tracker_rule_config.ex` (new), `runtime_config.ex`, `service_configs.ex`, `settings.ex` | DB rows, runtime getter, CRUD |
| `lib/mydia/indexers/tracker_rules.ex` (new) | `list_rules/0`, `rule_for/2`, `effective/3` |
| `lib/mydia/indexers/tracker_sightings.ex`, `tracker_sightings/{sighting,recorder}.ex` (new) | Sightings table, recorder, `list_trackers/1` |
| `lib/mydia/downloads/queue/client_selection.ex` | Freeze effective terms |
| `lib/mydia_web/live/admin_indexers_live/tracker_terms_{components,events}.ex` (new) | Admin section and modal |
| docs: env reference, `config/config.example.yml`, `lib/mydia/indexers/README.md` | Operator docs |

---

### Task 1: TrackerTerms struct and SearchResult.terms

**Files:** create `lib/mydia/indexers/structs/tracker_terms.ex`; modify
`lib/mydia/indexers/search_result.ex`; test
`test/mydia/indexers/structs/tracker_terms_test.exs`.

**Produces:**
- `%TrackerTerms{private?: boolean | nil, minimum_ratio: float | nil, minimum_seed_time: non_neg_integer | nil, download_volume_factor: float | nil, upload_volume_factor: float | nil}`
- `TrackerTerms.from_torznab(%{optional(String.t()) => String.t()}) :: t | nil` (keys `downloadvolumefactor`, `uploadvolumefactor`, `minimumratio`, `minimumseedtime`; blank or unparsable is nil; all nil gives nil)
- `TrackerTerms.parse_float/1`, `parse_seconds/1` (accept number or string)
- `TrackerTerms.to_map(t) :: %{String.t() => term}` with keys `private`, `minimum_ratio`, `minimum_seed_time`, `download_volume_factor`, `upload_volume_factor`
- `TrackerTerms.from_map(map | nil) :: t | nil` (string or atom keys)
- `TrackerTerms.empty?(t | nil) :: boolean`
- `SearchResult.terms :: TrackerTerms.t() | nil`, default nil

- [ ] Write tests: `from_torznab` parses `"0"`, `"0.5"`, `"1.0"`, `"259200"`; returns nil for all-blank input; `to_map`/`from_map` round trip including string keys after `Jason` round trip; `empty?`.
- [ ] Run, see failure; implement; run, see pass.
- [ ] Commit `feat(indexers): TrackerTerms struct on SearchResult`.

### Task 2: Torznab adapters (Jackett, Newznab)

**Files:** modify `adapter/jackett.ex`, `adapter/newznab.ex`; tests in
`test/mydia/indexers/adapter/{jackett,newznab}_test.exs`.

- [ ] Test: a Jackett Bypass feed whose item carries
  `<torznab:attr name="downloadvolumefactor" value="0"/>`, `uploadvolumefactor`
  `2`, `minimumratio` `1.0`, `minimumseedtime` `259200` yields
  `%TrackerTerms{download_volume_factor: 0.0, upload_volume_factor: 2.0, minimum_ratio: 1.0, minimum_seed_time: 259200, private?: nil}`; an item without them yields `terms: nil`.
- [ ] Same for Newznab with `newznab:attr` (and `torznab:attr` fallback).
- [ ] Implement: four xpath entries per adapter, `terms: TrackerTerms.from_torznab(...)`.
- [ ] Commit `feat(indexers): read tracker terms from Torznab attributes`.

### Task 3: Prowlarr adapter

**Files:** modify `adapter/prowlarr.ex`; `config/test.exs`
(`config :mydia, :prowlarr_privacy_lookup, false`); test
`test/mydia/indexers/adapter/prowlarr_test.exs`.

- [ ] Tests: `indexerFlags: ["freeleech"]` gives download factor 0.0;
  `halfleech` 0.5; `neutralleech` download and upload 0.0; `doubleupload`
  upload 2.0; explicit `minimumRatio`/`minimumSeedTime`/`downloadVolumeFactor`
  keys win over flags; with privacy lookup enabled (test sets app env and
  restores it), a `GET /api/v1/indexer` stub returning
  `[%{"id" => 7, "privacy" => "semiPrivate"}]` marks results with
  `"indexerId" => 7` private, and a failing lookup leaves `private?` nil and
  still returns results.
- [ ] Implement `prowlarr_terms(item, privacy_by_id)` in the adapter and a
  `Mydia.Indexers.Adapter.ProwlarrPrivacy` cache: a table-only GenServer
  started in `Mydia.Application` beside `ClientStatusCache` (an ETS table
  needs a long-lived owner), with `lookup(cache_key, fetch_fun)` keeping a
  successful map for one hour and a failure (as `%{}`) for five minutes. The
  key is `{host, port, base_path, :erlang.phash2(api_key)}`. When the table
  does not exist (a unit test without the app), `lookup/2` calls `fetch_fun`
  directly.
- [ ] Commit `feat(indexers): Prowlarr tracker terms from flags and privacy`.

### Task 4: Built-in Cardigann and WASM engine

> As built: privacy is added once for both engines by
> `AdapterSupport.put_definition_privacy/2` from the definition row's `type`,
> called at the end of each adapter's `search/3`, instead of threading
> `private?` through `Context` and the codec. Newznab reads `newznab:attr`
> only (its feeds declare no Torznab namespace).

**Files:** modify `cardigann/result/context.ex` (add `private?: nil`),
`cardigann_result_parser.ex` (set it from `definition.type in ["private", "semi-private"]`, false for `"public"`),
`cardigann/result/transform.ex` (terms from row fields `downloadvolumefactor`,
`uploadvolumefactor`, `minimumratio`, `minimumseedtime` plus `ctx.private?`),
`cardigann/wasm/codec.ex` (`decode_release/3` takes the terms fields; the
adapter passes the definition's privacy). Tests:
`test/mydia/indexers/cardigann/result/transform_test.exs` or the result parser
test, `test/mydia/indexers/cardigann/wasm/codec_test.exs`.

- [ ] Test: a private JSON definition with `downloadvolumefactor: {text: 0}`
  and `minimumseedtime: {text: 172800}` yields terms with `private?: true`,
  `download_volume_factor: 0.0`, `minimum_seed_time: 172800`; a public
  definition with none yields `%TrackerTerms{private?: false}`.
- [ ] Test: `Codec.decode_release/2` on a release map with
  `"download-volume-factor" => {:some, 0.5}`, `"minimum-ratio" => {:some, 1.0}`,
  `"minimum-seed-time" => {:some, 3600}` keeps them; `:none` is nil.
- [ ] Implement; find where the WASM adapter calls `decode_release` and pass
  privacy from the parsed definition.
- [ ] Commit `feat(indexers): tracker terms from both Cardigann engines`.

### Task 5: tracker_rules config, table and resolution

**Files:** `config/schema.ex` (`embeds_many :tracker_rules, TrackerRule`:
`tracker`, `seed_ratio` float, `seed_time` integer minutes, `private`
boolean), `config/schema/tracker_rule_changeset.ex`, `config/loader.ex`
(`TRACKER_RULE_<N>_TRACKER|SEED_RATIO|SEED_TIME|PRIVATE`, list key in
`deep_merge`), migration, `settings/tracker_rule_config.ex`,
`settings/runtime_config.ex` (`get_runtime_tracker_rules/0`),
`settings/service_configs.ex` + `settings.ex` delegates
(`list_tracker_rule_configs/0`, `get_tracker_rule_config!/1`,
`create_/update_/delete_tracker_rule_config`), `indexers/tracker_rules.ex`.
Tests: `test/mydia/config/tracker_rules_config_test.exs`,
`test/mydia/indexers/tracker_rules_test.exs`.

**Produces:**
- `TrackerRuleConfig` schema: `id`, `tracker`, `seed_ratio`, `seed_time` (minutes), `private`, `updated_by_id`, timestamps; unique on `lower(tracker)` via a stored `tracker_key`.
- `TrackerRules.key(String.t()) :: String.t()` (trim + downcase)
- `TrackerRules.list_rules() :: [TrackerRuleConfig.t()]` (DB shadows runtime by key)
- `TrackerRules.rule_for(tracker, rules \\ list_rules()) :: TrackerRuleConfig.t() | nil`
- `TrackerRules.effective(TrackerTerms.t() | nil, tracker, rules \\ list_rules()) :: TrackerTerms.t() | nil`

- [ ] Test precedence table: (override set, reported set) gives override;
  (nil, set) gives reported; (set, nil) gives override; (nil, nil) gives nil;
  for ratio, seed time (minutes to seconds) and private; volume factors pass
  through; matching is case-insensitive and trims; DB row shadows a runtime
  rule with the same tracker in another case.
- [ ] Test env loading: `TRACKER_RULE_1_TRACKER=Velvet Lantern`,
  `..._SEED_RATIO=1.5`, `..._SEED_TIME=4320`, `..._PRIVATE=true` loads one rule;
  a negative ratio is a config error.
- [ ] Implement; migration `create_tracker_rule_configs_and_sightings` (both
  tables, see Task 6).
- [ ] Commit `feat(indexers): per-tracker term overrides in layered config`.

### Task 6: Freeze terms at grab

**Files:** `downloads/queue/client_selection.ex`; test
`test/mydia/downloads/tracker_terms_freeze_test.exs`.

- [ ] Test: grabbing (via `Queue.build_download_metadata/1` and
  `History.create_download/1`) a result with reported terms and an override
  stores `metadata["tracker_terms"]` with the override applied after reload;
  updating the override afterwards leaves the stored map unchanged; a result
  with no terms and no rule stores no key.
- [ ] Implement `maybe_put_tracker_terms/2` in `build_download_metadata/1`.
- [ ] Commit `feat(downloads): freeze effective tracker terms at grab`.

### Task 7: Tracker sightings

**Files:** `indexers/tracker_sightings.ex`, `tracker_sightings/sighting.ex`,
`tracker_sightings/recorder.ex`, `application.ex`, `indexers.ex`
(`search_all/2` calls `TrackerSightings.record(all_results)`). Test
`test/mydia/indexers/tracker_sightings_test.exs`.

**Produces:**
- table `tracker_sightings`: `id`, `tracker_key` (unique), `tracker`, `private` boolean, `minimum_ratio` float, `minimum_seed_time` integer, `last_seen_at` utc_datetime.
- `TrackerSightings.record([SearchResult.t()]) :: :ok` (sync under the SQL sandbox, otherwise buffered, flushed every 60s; a known field is never overwritten by nil)
- `TrackerSightings.list_trackers(now \\ DateTime.utc_now()) :: [%TrackerSightings.Row{}]`: trackers seen in 30 days plus every rule, each with `tracker`, `key`, `reported`, `effective`, `rule`, `last_seen_at`, `stale?` (a rule whose tracker was neither seen nor grabbed in 30 days, and, for a DB rule, older than 30 days).

- [ ] Tests: recording two results from one tracker upserts one row; a later
  record with nil ratio keeps the earlier ratio; `list_trackers` orders by
  name, flags a rule with no sighting as stale, does not flag one seen 10 days
  ago or one with a `Download` in 30 days, flags one seen 40 days ago.
- [ ] Implement; commit `feat(indexers): remember trackers seen in search results`.

### Task 8: Admin UI

**Files:** `admin_indexers_live/tracker_terms_components.ex`,
`admin_indexers_live/tracker_terms_events.ex`, `components.ex`
(`indexers_tab` renders the section, `modals` renders the modal),
`index.ex` (attach hook), `index.html.heex` (pass assign). Test
`test/mydia_web/live/admin_indexers_live/tracker_terms_test.exs`.

- [ ] Tests (`async: false`): with a sighting and a DB rule, the page has
  `#tracker-terms-section` and `#tracker-<key>` rows; a rule with no sighting
  shows `#tracker-stale-<key>`; clicking `#edit-tracker-rule-<key>` opens
  `#tracker-rule-modal`, submitting `#tracker-rule-form` creates the rule and
  the row shows the new effective ratio; an env rule's edit is disabled.
- [ ] Implement with `admin_section`, `admin_list`, `admin_row`, `row_action`,
  `env_lock_badge`, `admin_modal`; events `new_tracker_rule`,
  `edit_tracker_rule`, `validate_tracker_rule`, `save_tracker_rule`,
  `delete_tracker_rule`, `close_tracker_rule_modal`.
- [ ] `./dev mix gettext.extract`; commit `feat(admin): tracker terms on the Indexers page`.

### Task 9: Docs

- [ ] `docs/using/reference/environment-variables.md`: "Tracker rules" table.
- [ ] `config/config.example.yml`: commented `tracker_rules` example with a fictional tracker.
- [ ] `lib/mydia/indexers/README.md`: "Tracker terms" section (sources per adapter, Prowlarr flags mapping, precedence, freezing, sightings and the stale flag).
- [ ] Update the spec's Spec 0 section with the Prowlarr and Jackett deviations.
- [ ] Commit `docs(indexers): tracker terms and overrides`.
