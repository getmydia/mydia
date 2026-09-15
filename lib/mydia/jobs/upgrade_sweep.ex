defmodule Mydia.Jobs.UpgradeSweep do
  @moduledoc """
  Daily bounded sweep that looks for replacements for files already on disk:
  quality upgrades for files below their profile's cutoff, and audio language
  replacements for files missing the preferred language.

  The existing hourly `MovieSearch` and 30 minute `TVShowSearch` crons only
  consider items with **no** file, a small and shrinking set. Upgrade-eligible
  items can be the entire library, so this sweep is deliberately slow and
  hard-capped: `upgrades.sweep_batch_size` (layered runtime config) bounds how
  many indexer searches a single run may cost.

  Items are stamped at enqueue time rather than on search completion, so an
  item whose searches always fail cannot monopolise the front of the queue.

  One of movies or episodes leads each run and gets first crack at the
  budget; the other gets whatever remains. The lead alternates by calendar
  day (or can be forced via the `"lead"` job arg) rather than always
  favouring movies — a library with `sweep_batch_size` or more below-cutoff
  movies would otherwise leave `remaining` at 0 for episodes on every single
  run, since stamping only rotates *which* movies get picked, never shrinks
  the eligible set (a below-cutoff movie stays below cutoff until an actual
  upgrade file is imported).

  ## Reasons

  `Mydia.Upgrades.eligible_movies/1` and `eligible_episodes/1` find quality
  candidates; `language_eligible_movies/2` and `language_eligible_episodes/2`
  find language candidates. `Mydia.Upgrades.merge_candidates/3` folds them
  into one entry per movie or episode carrying `reasons`, so one search serves
  both, and the job args carry the reasons so the search backs off in each
  reason's own bucket. Quality stamps `last_upgrade_check_at` and language
  stamps `last_language_check_at`, each only for candidates it searched.

  A run with a `"media_item_id"` arg is scoped to that item and runs the
  language scan alone: an audio language change cannot move any file across
  its quality cutoff. `enqueue_for_item/1` enqueues one.

  Episodes are not searched one-by-one: they are grouped by `{show, season}`
  and routed through `TVShowSearch.should_prefer_season_pack?/3` (the same
  70% threshold the missing-episode search path uses), so a season where
  most episodes are below cutoff costs one season-pack search instead of one
  search per episode. The budget tracked here counts indexer searches, not
  items — a season pack costs 1 regardless of how many episodes it covers.
  """

  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
    # :args is part of uniqueness so a run scoped to one item never collides
    # with the daily run, whose args are empty. Only in-flight runs count
    # (`states: :incomplete`), so a finished scoped run never blocks the
    # follow-up to a later change.
    unique: [period: 3600, fields: [:worker, :args], states: :incomplete]

  require Logger

  alias Mydia.Jobs.MovieSearch
  alias Mydia.Jobs.TVShowSearch
  alias Mydia.Repo
  alias Mydia.Upgrades
  alias Mydia.Upgrades.Reasons

  @default_batch_size 50

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if enabled?() do
      run(batch_size(), lead(args), scope(args))
    else
      Logger.debug("Upgrade sweep disabled, skipping")
      {:ok, :disabled}
    end
  end

  @doc """
  Enqueues a language-only sweep for one media item, the follow-up to a change
  in its audio language override. A failed enqueue is logged and swallowed:
  the daily run still reaches the item.
  """
  @spec enqueue_for_item(binary()) :: :ok
  def enqueue_for_item(media_item_id) when is_binary(media_item_id) do
    case %{"media_item_id" => media_item_id} |> new() |> insert_job() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue scoped upgrade sweep",
          media_item_id: media_item_id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp scope(%{"media_item_id" => media_item_id}) when is_binary(media_item_id),
    do: media_item_id

  defp scope(_args), do: nil

  # Explicit for tests (and any future manual trigger); otherwise derived
  # from the calendar day so alternation is deterministic across runs on the
  # same day without needing to persist state between sweeps.
  defp lead(%{"lead" => "movies"}), do: :movies
  defp lead(%{"lead" => "episodes"}), do: :episodes

  defp lead(_args) do
    if rem(Date.utc_today() |> Date.to_gregorian_days(), 2) == 0 do
      :movies
    else
      :episodes
    end
  end

  defp run(budget, lead, scope) do
    {searches, movie_candidates} =
      case lead do
        :movies ->
          {movie_searches, movie_candidates} = sweep_movies(budget, scope)
          episode_searches = sweep_episodes(max(budget - movie_searches, 0), scope)
          {movie_searches + episode_searches, movie_candidates}

        :episodes ->
          episode_searches = sweep_episodes(budget, scope)

          {movie_searches, movie_candidates} =
            sweep_movies(max(budget - episode_searches, 0), scope)

          {movie_searches + episode_searches, movie_candidates}
      end

    Logger.info("Upgrade sweep complete",
      candidates: movie_candidates,
      searches: searches,
      budget: budget,
      lead: lead,
      media_item_id: scope
    )

    {:ok, %{searches: searches, candidates: movie_candidates}}
  end

  defp sweep_movies(0, _scope), do: {0, 0}

  defp sweep_movies(budget, scope) do
    candidates =
      budget
      |> quality_movies(scope)
      |> Upgrades.merge_candidates(
        Upgrades.language_eligible_movies(budget, scope_opts(scope)),
        & &1.media_item.id
      )
      |> Enum.take(budget)

    searches =
      candidates
      |> Enum.map(&enqueue_movie/1)
      |> Enum.count(& &1)

    Upgrades.stamp_checked(:movie, ids_for(candidates, :quality, & &1.media_item.id))
    Upgrades.stamp_language_checked(:movie, ids_for(candidates, :language, & &1.media_item.id))

    {searches, length(candidates)}
  end

  defp quality_movies(budget, nil), do: Upgrades.eligible_movies(budget)
  defp quality_movies(_budget, _media_item_id), do: []

  defp quality_episodes(budget, nil), do: Upgrades.eligible_episodes(budget)
  defp quality_episodes(_budget, _media_item_id), do: []

  defp scope_opts(nil), do: []
  defp scope_opts(media_item_id), do: [media_item_id: media_item_id]

  defp ids_for(candidates, reason, id_fun) do
    for candidate <- candidates, reason in candidate.reasons, do: id_fun.(candidate)
  end

  # Like ids_for/3, but reads the reasons actually searched for each
  # candidate rather than the candidate's own full `.reasons` - see
  # plan_group/3, which narrows a season pack's per-candidate reasons to the
  # ones the pack itself carried.
  defp ids_for_searched(attempted, reason, id_fun) do
    for {candidate, searched_reasons} <- attempted,
        reason in searched_reasons,
        do: id_fun.(candidate)
  end

  # Episodes are not swept one at a time. A season where most episodes are
  # below cutoff is better served by one season-pack search than by N
  # individual ones, so candidates are grouped by {show, season} and routed
  # through TVShowSearch.should_prefer_season_pack?/3 before anything is
  # enqueued.
  #
  # `Upgrades.eligible_episodes/1` does not truncate to `budget` (a season
  # pack can turn many episodes into one search, so item count and search
  # count diverge — truncating there could split a season's below-cutoff
  # episodes across the boundary and corrupt the pack-threshold percentage).
  # So the search-cost budget is enforced here instead: each group's cost is
  # computed by `plan_group/3` *before* anything is enqueued.
  #
  # A group whose cost exceeds the *remaining* budget is skipped, not the
  # whole run aborted — smaller, affordable groups later in iteration order
  # must still get their turn. `Enum.group_by/2` returns a map, and Erlang's
  # small-map representation iterates keys in term order, so an early-sorting
  # oversized `{media_item_id, season_number}` would otherwise deterministically
  # zero out every affordable group behind it, on every single run — the
  # same permanent-starvation shape as the movies-first bug fixed elsewhere
  # in this module. Only once the remaining budget hits 0 (nothing left that
  # any group, minimum cost 1, could ever fit into) does the fold stop
  # scanning further groups.
  #
  # Stamping mirrors this: only episodes whose group's plan was actually
  # attempted (enqueued, whether that enqueue succeeded or failed) get
  # stamped. A skipped group is left unstamped, so a later run — with more
  # budget, or once other work clears — can still pick it up. This is
  # narrower than the anti-starvation rule elsewhere (stamp candidates
  # regardless of enqueue *failure*, so a search that always errors can't
  # camp at the front of the staleness order forever) — that rule is about
  # not letting failed attempts dodge the stamp, not about stamping work
  # that was never attempted at all.
  defp sweep_episodes(0, _scope), do: 0

  defp sweep_episodes(budget, scope) do
    candidates =
      budget
      |> quality_episodes(scope)
      |> Upgrades.merge_candidates(
        Upgrades.language_eligible_episodes(budget, scope_opts(scope)),
        & &1.episode.id
      )

    groups =
      candidates
      |> Enum.group_by(fn c -> {c.episode.media_item_id, c.episode.season_number} end)
      |> Enum.map(fn {{item_id, season}, group} -> plan_group(item_id, season, group) end)

    {searches, attempted} =
      Enum.reduce_while(groups, {0, []}, fn {plan, searched}, {spent, attempted} ->
        remaining = budget - spent
        cost = length(plan)

        cond do
          remaining <= 0 ->
            {:halt, {spent, attempted}}

          cost > remaining ->
            {:cont, {spent, attempted}}

          true ->
            enqueued = Enum.count(plan, &(enqueue(&1) == 1))
            {:cont, {spent + enqueued, [searched | attempted]}}
        end
      end)

    attempted = List.flatten(attempted)
    Upgrades.stamp_checked(:episode, ids_for_searched(attempted, :quality, & &1.episode.id))

    Upgrades.stamp_language_checked(
      :episode,
      ids_for_searched(attempted, :language, & &1.episode.id)
    )

    searches
  end

  # Decides pack-vs-individual and returns {plan, searched}, without
  # enqueuing anything. `plan` is the list of TVShowSearch args this group
  # would need; its length is the group's search cost, always 1 for a pack
  # regardless of how many episodes it covers, or one entry per episode
  # otherwise, letting the caller check whether it fits the remaining
  # budget before committing to it. `searched` is a {candidate,
  # searched_reasons} pair per candidate in the group, for stamping: a
  # season pack narrows its reasons to the ones whose season bucket is open
  # (see below), so a candidate must only be stamped for the intersection
  # of its own reasons with what the pack actually carried, not its full
  # `.reasons`. Not pure (it reads season_pack_upgrade_eligible?/2's backoff
  # row), but idempotent and side-effect-free otherwise.
  #
  # Reuses TVShowSearch's existing 70% missing-episode threshold unchanged;
  # only the input set changes, from "episodes missing" to "episodes below
  # cutoff". The comparison target for a pack search is the best-scoring
  # below-cutoff file in the season: beating the best means beating all of
  # them, the conservative reading.
  #
  # A season whose pack search keeps finding no qualifying pack backs off
  # in TVShowSearch's "season_upgrade" SearchBackoff bucket (see
  # Mydia.Jobs.TVShowSearch.search_season_upgrade/4) - re-searching it here
  # on every sweep that reaches it would be the same unbounded indexer cost
  # the no-fallback rule inside that job exists to prevent. A season in
  # that backoff window falls through to the individual-episode branch
  # instead of being skipped outright: each episode's own "episode_upgrade"
  # backoff (a different, per-episode bucket) still gates it independently,
  # so this is a genuinely different, still-useful search, not a retry of
  # the suppressed one.
  #
  # A pack search carries only the reasons whose season bucket is open
  # (Upgrades.bucket_open?/4, which for language also honours the 90-day
  # give-up). When none is open the group falls through to individual
  # searches, each carrying its own episode's reasons.
  defp plan_group(item_id, season, group) do
    media_item = hd(group).episode.media_item
    episodes = Enum.map(group, & &1.episode)

    pack_reasons =
      if TVShowSearch.should_prefer_season_pack?(episodes, media_item, season) do
        group
        |> Enum.flat_map(& &1.reasons)
        |> Enum.uniq()
        |> Enum.filter(&Upgrades.bucket_open?(:season, &1, item_id, season_number: season))
      else
        []
      end

    case pack_reasons do
      [] ->
        plan =
          Enum.map(group, fn c ->
            %{
              "mode" => "upgrade_episode",
              "episode_id" => c.episode.id,
              "media_file_id" => c.media_file.id,
              "reasons" => Reasons.encode(c.reasons)
            }
          end)

        {plan, Enum.map(group, &{&1, &1.reasons})}

      _ ->
        target = Enum.max_by(group, & &1.score)

        plan = [
          %{
            "mode" => "upgrade_season",
            "media_item_id" => item_id,
            "season_number" => season,
            "media_file_id" => target.media_file.id,
            "reasons" => Reasons.encode(pack_reasons)
          }
        ]

        searched = Enum.map(group, &{&1, Enum.filter(&1.reasons, fn r -> r in pack_reasons end)})
        {plan, searched}
    end
  end

  # Returns the search cost incurred: 1 on a successful enqueue, 0 on
  # failure. Mirrors enqueue_movie/1's fail-open behaviour — one job that
  # fails to enqueue is logged and skipped, never failing the batch.
  defp enqueue(args) do
    case args |> TVShowSearch.new() |> insert_job() do
      {:ok, _job} ->
        1

      {:error, reason} ->
        Logger.warning("Failed to enqueue upgrade search",
          args: args,
          reason: inspect(reason)
        )

        0
    end
  end

  # One item that fails to enqueue is logged and skipped, never failing the
  # batch. Mirrors Mydia.Search.queue_auto_searches/1.
  #
  # NOTE for test authors: like Mydia.Search.insert_jobs/2, the {:error,
  # reason} branch below cannot be forced through this module's public API in
  # this test suite. Oban.Job's schema has no FK or unique DB constraint tied
  # to the business ids carried in `args` (only fixed CHECK constraints on
  # :attempt/:max_attempts/:priority, none of which this function's callers
  # can influence), and this project has no mocking library wired up to stub
  # Repo.insert/1. See test/mydia/jobs/upgrade_sweep_test.exs for the
  # evidence trail.
  defp enqueue_movie(%{media_item: item, media_file: file, reasons: reasons}) do
    args = %{
      "mode" => "upgrade",
      "media_item_id" => item.id,
      "media_file_id" => file.id,
      "reasons" => Reasons.encode(reasons)
    }

    case args |> MovieSearch.new() |> insert_job() do
      {:ok, _job} ->
        true

      {:error, reason} ->
        Logger.warning("Failed to enqueue upgrade search",
          media_item_id: item.id,
          reason: inspect(reason)
        )

        false
    end
  end

  defp insert_job(changeset) do
    Oban.insert(changeset)
  rescue
    RuntimeError -> Repo.insert(changeset)
  end

  # Reads through the layered runtime config (env > DB/UI > YAML > schema
  # defaults; see Mydia.Config.Loader) rather than a flat
  # Application.get_env(:mydia, :upgrade_sweep_enabled, ...) key. Nothing in
  # this codebase ever explodes the resolved Mydia.Config.Schema struct back
  # out to flat top-level Application env keys — Config.Loader.reload/1 only
  # writes Application.get_env(:mydia, :runtime_config, ...) — so a flat read
  # here would silently ignore both the UPGRADE_SWEEP_ENABLED env var and the
  # runtime settings UI/DB. Do not revert to a flat read: the identical
  # mistake on oban.poll_interval/max_age_days is tracked as
  # https://github.com/getmydia/mydia/issues/271.
  defp enabled? do
    case Mydia.Config.get() do
      %{upgrades: %{sweep_enabled: enabled}} when is_boolean(enabled) -> enabled
      _ -> true
    end
  end

  # See enabled?/0 above for why this reads through the layered config
  # instead of a flat Application.get_env(:mydia, :upgrade_sweep_batch_size, ...) key.
  defp batch_size do
    case Mydia.Config.get() do
      %{upgrades: %{sweep_batch_size: size}} when is_integer(size) and size > 0 -> size
      _ -> @default_batch_size
    end
  end
end
