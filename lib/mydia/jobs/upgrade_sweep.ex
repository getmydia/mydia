defmodule Mydia.Jobs.UpgradeSweep do
  @moduledoc """
  Daily bounded sweep that looks for quality upgrades to already-present files.

  The existing hourly `MovieSearch` and 30 minute `TVShowSearch` crons only
  consider items with **no** file, a small and shrinking set. Upgrade-eligible
  items can be the entire library, so this sweep is deliberately slow and
  hard-capped: `upgrades.sweep_batch_size` (layered runtime config) bounds how
  many indexer searches a single run may cost.

  Items are stamped at enqueue time rather than on search completion, so an
  item whose searches always fail cannot monopolise the front of the queue.

  Movies are swept first; episodes get whatever budget remains. Episodes are
  not searched one-by-one: they are grouped by `{show, season}` and routed
  through `TVShowSearch.should_prefer_season_pack?/3` (the same 70% threshold
  the missing-episode search path uses), so a season where most episodes are
  below cutoff costs one season-pack search instead of one search per
  episode. The budget tracked here counts indexer searches, not items — a
  season pack costs 1 regardless of how many episodes it covers.
  """

  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
    unique: [period: 3600, fields: [:worker]]

  require Logger

  alias Mydia.Jobs.MovieSearch
  alias Mydia.Jobs.TVShowSearch
  alias Mydia.Repo
  alias Mydia.Upgrades

  @default_batch_size 50

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if enabled?() do
      run(batch_size())
    else
      Logger.debug("Upgrade sweep disabled, skipping")
      {:ok, :disabled}
    end
  end

  defp run(budget) do
    movies = Upgrades.eligible_movies(budget)

    movie_searches =
      movies
      |> Enum.map(&enqueue_movie/1)
      |> Enum.count(& &1)

    Upgrades.stamp_checked(:movie, Enum.map(movies, & &1.media_item.id))

    remaining = max(budget - movie_searches, 0)
    episode_searches = sweep_episodes(remaining)

    searches = movie_searches + episode_searches

    Logger.info("Upgrade sweep complete",
      candidates: length(movies),
      searches: searches,
      budget: budget
    )

    {:ok, %{searches: searches, candidates: length(movies)}}
  end

  # Episodes are not swept one at a time. A season where most episodes are
  # below cutoff is better served by one season-pack search than by N
  # individual ones, so candidates are grouped by {show, season} and routed
  # through TVShowSearch.should_prefer_season_pack?/3 before anything is
  # enqueued.
  #
  # `budget` is both the item-fetch limit passed to Upgrades.eligible_episodes/1
  # and the search-cost ceiling this function enforces. Since a group's search
  # cost never exceeds its item count (1 for a pack regardless of size, 1 per
  # episode otherwise), and eligible_episodes/1 never returns more than
  # `budget` items, total cost can never exceed `budget` — the check below is
  # a defensive stop, not the sole guarantee. It does mean a below-cutoff
  # season can be truncated by the fetch limit before grouping ever sees it:
  # a season that would clear the 70% pack threshold in full may fall short
  # of it when only a budget-limited slice of its episodes is visible, and
  # route to (budget-many) individual searches instead of one pack search.
  defp sweep_episodes(0), do: 0

  defp sweep_episodes(budget) do
    candidates = Upgrades.eligible_episodes(budget)

    searches =
      candidates
      |> Enum.group_by(fn c -> {c.episode.media_item_id, c.episode.season_number} end)
      |> Enum.reduce_while(0, fn {{item_id, season}, group}, spent ->
        if spent >= budget do
          {:halt, spent}
        else
          {:cont, spent + enqueue_season_group(item_id, season, group)}
        end
      end)

    Upgrades.stamp_checked(:episode, Enum.map(candidates, & &1.episode.id))
    searches
  end

  # Reuses TVShowSearch's existing 70% missing-episode threshold unchanged;
  # only the input set changes, from "episodes missing" to "episodes below
  # cutoff". The comparison target for a pack search is the best-scoring
  # below-cutoff file in the season: beating the best means beating all of
  # them, the conservative reading.
  defp enqueue_season_group(item_id, season, group) do
    media_item = hd(group).episode.media_item
    episodes = Enum.map(group, & &1.episode)

    if TVShowSearch.should_prefer_season_pack?(episodes, media_item, season) do
      target = Enum.max_by(group, & &1.score)

      enqueue(%{
        "mode" => "upgrade_season",
        "media_item_id" => item_id,
        "season_number" => season,
        "media_file_id" => target.media_file.id
      })
    else
      group
      |> Enum.map(fn c ->
        enqueue(%{
          "mode" => "upgrade_episode",
          "episode_id" => c.episode.id,
          "media_file_id" => c.media_file.id
        })
      end)
      |> Enum.sum()
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
  defp enqueue_movie(%{media_item: item, media_file: file}) do
    args = %{
      "mode" => "upgrade",
      "media_item_id" => item.id,
      "media_file_id" => file.id
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
