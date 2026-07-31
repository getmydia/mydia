defmodule Mydia.Jobs.UpgradeSweep do
  @moduledoc """
  Daily bounded sweep that looks for quality upgrades to already-present files.

  The existing hourly `MovieSearch` and 30 minute `TVShowSearch` crons only
  consider items with **no** file, a small and shrinking set. Upgrade-eligible
  items can be the entire library, so this sweep is deliberately slow and
  hard-capped: `:upgrade_sweep_batch_size` bounds how many indexer searches a
  single run may cost.

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

  defp enabled?, do: Application.get_env(:mydia, :upgrade_sweep_enabled, true)

  defp batch_size do
    Application.get_env(:mydia, :upgrade_sweep_batch_size, @default_batch_size)
  end
end
