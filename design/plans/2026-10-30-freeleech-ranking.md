# Freeleech Ranking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a quality profile prefer freeleech releases (Spec 2 of
`design/specs/2026-10-30-private-trackers-roadmap-design.md`), and show a
release's tracker terms in the manual search dialog.

**Architecture:** A new `quality_standards` key, `freeleech_preference`
(`"ignore"` default, `"prefer"`), validated by a small
`Mydia.Settings.QualityProfile.FreeleechPreference` module and classified as a
preference in `Mydia.Indexers.ProfileLimits`. `SearchScorer` adds
`freeleech_bonus = (1 - download_volume_factor) * 10` to the combined score
beside `availability_score` and `title_bonus`. `score_quality/3` and
`QualityProfile.score_media_file/2` never see it, so grab delay's
`upgrade_until_score` check and upgrades are untouched. `ReleaseRanker.explain/2`
carries it into `ScoreBreakdown.freeleech`, which the manual search score panel
renders. A new function component renders `FL` / `50%` / `2x up` badges and a
private icon from `SearchResult.terms`.

**Tech Stack:** Elixir, Ecto changesets, Phoenix LiveView function components,
daisyUI badges, gettext.

## Global Constraints

- Freeleech enters only `SearchScorer`'s combined score, never `score_quality/3` or `QualityProfile.score_media_file/2`.
- `freeleech_bonus = (1 - download_volume_factor) * 10` when `prefer`; 0 when the factor is unknown or the setting is `ignore`.
- The upload factor is shown, not scored.
- `ReleaseRanker.explain/2` lists the bonus; no second scoring path for display.
- Ratchet: `quality_profile.ex` (940) and `release_ranker.ex` (985) are over 800 lines and may not grow.
- gettext for every user-visible string; unique DOM ids; no em dashes; no real titles or tracker names.

## Files

- Create `lib/mydia/settings/quality_profile/freeleech_preference.ex`: allowed values, `validate/2`, `prefer?/1`.
- Modify `lib/mydia/settings/quality_profile.ex`: call the validator; compact `@valid_video_codecs`/`@valid_audio_codecs` to `~w()` so the file shrinks.
- Modify `lib/mydia/indexers/profile_limits.ex`: `:freeleech_preference` in `@preference_keys`.
- Modify `lib/mydia/indexers/search_scorer.ex`: `score_freeleech/2`, combined score, breakdown key `:freeleech_bonus`.
- Modify `lib/mydia/indexers/structs/score_breakdown.ex`: `freeleech: 0.0`.
- Modify `lib/mydia/indexers/release_ranker.ex`: map `:freeleech_bonus` into the struct, net zero lines.
- Create `lib/mydia_web/live/media_live/show/tracker_terms_badges.ex`: `terms_badges/1`.
- Modify `lib/mydia_web/live/media_live/show/manual_search_components.ex`: render badges and a Freeleech score row.
- Modify `lib/mydia_web/live/admin_quality_profiles_live/standards_tab.ex`: a select for the setting.
- Docs: `lib/mydia/indexers/README.md` table, `docs/using/explanation/quality-decisions.md`.

---

### Task 1: The setting and its classification

**Files:** freeleech_preference.ex (create), quality_profile.ex, profile_limits.ex,
standards_tab.ex; tests `test/mydia/settings/quality_profile/freeleech_preference_test.exs`,
`test/mydia/indexers/profile_limits_test.exs` (existing classification test).

**Produces:** `FreeleechPreference.values/0 :: [String.t()]`,
`FreeleechPreference.prefer?(QualityProfile.t() | nil) :: boolean()`,
`FreeleechPreference.validate(Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()`.

- [ ] Step 1: add the select to `standards_tab.ex` (name
  `quality_profile[quality_standards][freeleech_preference]`, options `ignore`
  and `prefer`). Run `profile_limits_test.exs`: the classification test fails
  naming `:freeleech_preference`.
- [ ] Step 2: add `:freeleech_preference` to `@preference_keys`. Test passes.
- [ ] Step 3: write `freeleech_preference_test.exs`:

```elixir
test "accepts ignore and prefer, rejects anything else" do
  for v <- ["ignore", "prefer"] do
    assert QualityProfile.changeset(%QualityProfile{}, attrs(v)).valid?
  end
  refute QualityProfile.changeset(%QualityProfile{}, attrs("always")).valid?
end

test "prefer?/1 is true only for prefer" do
  assert FreeleechPreference.prefer?(profile(%{freeleech_preference: "prefer"}))
  refute FreeleechPreference.prefer?(profile(%{freeleech_preference: "ignore"}))
  refute FreeleechPreference.prefer?(profile(%{}))
  refute FreeleechPreference.prefer?(nil)
end
```

  (`attrs(v)` = name plus `quality_standards: %{preferred_resolutions: ["1080p"], freeleech_preference: v}`.)
- [ ] Step 4: implement:

```elixir
defmodule Mydia.Settings.QualityProfile.FreeleechPreference do
  import Ecto.Changeset
  @values ~w(ignore prefer)
  def values, do: @values
  def prefer?(%{quality_standards: %{} = s}), do: Map.get(s, :freeleech_preference) == "prefer"
  def prefer?(_), do: false
  def validate(changeset, standards) do
    case Map.get(standards, :freeleech_preference) do
      v when v in [nil | @values] -> changeset
      _ -> add_error(changeset, :quality_standards, "freeleech_preference must be one of: ignore, prefer")
    end
  end
end
```

  and pipe `|> FreeleechPreference.validate(standards)` in
  `validate_quality_standards/1`; compact the codec lists so the file shrinks.
- [ ] Step 5: run both tests plus `test/mydia/settings/quality_profile_test.exs`
  and `test/mydia_web/live/admin_quality_profiles_live_test.exs`; commit
  `feat(quality): add freeleech_preference to quality profiles`.

### Task 2: Score the bonus

**Files:** search_scorer.ex, score_breakdown.ex, release_ranker.ex; tests in
`test/mydia/indexers/search_scorer_test.exs` and `release_ranker_test.exs`
(`describe "explain/2"`).

**Consumes:** `FreeleechPreference.prefer?/1`. **Produces:**
`SearchScorer.score_freeleech(SearchResult.t(), QualityProfile.t() | nil) :: float()`,
breakdown key `:freeleech_bonus`, `ScoreBreakdown.freeleech :: float()`.

- [ ] Step 1: failing scorer tests, `describe "freeleech bonus"`: with
  `prefer`, factor 0.0 adds 10.0, 0.5 adds 5.0, `terms: nil` and a nil factor
  add 0.0; with `ignore` (or no key) factor 0.0 adds 0.0; the combined score of
  the full-freeleech result is exactly 10.0 above the same result with no
  terms; `score_quality/3` returns the same tuple for both; upload factor 2.0
  alone adds nothing.
- [ ] Step 2: implement:

```elixir
def score_freeleech(%SearchResult{terms: %TrackerTerms{download_volume_factor: f}}, profile)
    when is_number(f) do
  if FreeleechPreference.prefer?(profile), do: (1 - min(max(f, 0), 1)) * 10.0, else: 0.0
end
def score_freeleech(_result, _profile), do: 0.0
```

  The factor is clamped to 0..1 so a bogus factor above 1 cannot subtract.
  Add it inside the combined sum and `Map.put(:freeleech_bonus, ...)`; update
  the moduledoc formula.
- [ ] Step 3: failing explain test: a `prefer` profile and a factor-0 result
  give `breakdown.freeleech == 10.0`, and its `total` is 10.0 above the
  no-terms result. Add `freeleech: 0.0` to `ScoreBreakdown` and
  `freeleech: round_score(Map.get(breakdown, :freeleech_bonus, 0.0))` in
  `explain/2`, removing two comment lines to keep `release_ranker.ex` at 985.
- [ ] Step 4: run scorer, ranker, grab delay and profile limits tests; commit
  `feat(indexers): rank freeleech releases higher when the profile prefers it`.

### Task 3: Manual search badges and breakdown row

**Files:** tracker_terms_badges.ex (create), manual_search_components.ex;
tests `test/mydia_web/live/media_live/show/tracker_terms_badges_test.exs`, a
row test in `modals_test.exs`.

- [ ] Step 1: failing component tests with `render_component` and LazyHTML:
  factor 0 renders `#x-freeleech` with text `FL`; 0.5 renders `50%`; upload 2.0
  renders `#x-upload` with `2x up`; `private?: true` renders `#x-private`; nil
  terms and factor 1.0/upload 1.0 render nothing.
- [ ] Step 2: implement `terms_badges/1` (attrs `id`, `terms`), daisyUI
  `badge badge-sm` (`badge-success` for FL, `badge-info` for partial and
  upload, `hero-lock-closed` icon for private), titles via gettext.
- [ ] Step 3: render it in the row's badge strip; add a `score_row` labelled
  Freeleech when `@breakdown.freeleech > 0`. Row test in `modals_test.exs`
  asserts the badge id appears for a result with factor-0 terms.
- [ ] Step 4: `mix gettext.extract --merge`; run tests; commit
  `feat(web): show tracker terms badges in manual search`.

### Task 4: Docs

- [ ] Add `freeleech_preference` to the limits-vs-preferences table in
  `lib/mydia/indexers/README.md` and a short paragraph; add a subsection to
  `docs/using/explanation/quality-decisions.md` "What the score actually
  weighs". Commit `docs: document freeleech_preference`.
