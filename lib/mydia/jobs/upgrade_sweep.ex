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
  """

  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
    unique: [period: 3600, fields: [:worker]]

  require Logger

  alias Mydia.Jobs.MovieSearch
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
    candidates = Upgrades.eligible_movies(budget)

    searches =
      candidates
      |> Enum.map(&enqueue_movie/1)
      |> Enum.count(& &1)

    Upgrades.stamp_checked(:movie, Enum.map(candidates, & &1.media_item.id))

    Logger.info("Upgrade sweep complete",
      candidates: length(candidates),
      searches: searches,
      budget: budget
    )

    {:ok, %{searches: searches, candidates: length(candidates)}}
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
