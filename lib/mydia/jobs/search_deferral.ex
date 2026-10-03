defmodule Mydia.Jobs.SearchDeferral do
  @moduledoc """
  What an automatic search does when `Mydia.Indexers.GrabDelay` says wait.

  It records a `search.deferred` event so the item's activity explains why
  nothing was grabbed, and schedules a re-check for the unit that waited. The
  re-check matters because upgrades only run from the nightly
  `Mydia.Jobs.UpgradeSweep`, and the cron searches run every 30 or 60
  minutes; without it a delayed upgrade would sit until the next night.

  The re-check is unique on worker and args while scheduled or available, so
  cron passes during the wait do not stack copies. It never carries
  `bypass_delay`. A wait records no search backoff: nothing failed.
  """

  import Ecto.Query, only: [where: 3, select: 3]

  require Logger

  alias Mydia.Events
  alias Mydia.Media.MediaItem

  # The re-check runs just after the delay ends rather than on it, so it does
  # not land a second early and wait again.
  @slack_seconds 60

  @spec defer(module(), map(), DateTime.t(), MediaItem.t(), map(), keyword()) :: :ok
  def defer(
        worker,
        recheck_args,
        until,
        %MediaItem{} = media_item,
        event_metadata,
        event_opts \\ []
      ) do
    changeset =
      worker.new(recheck_args,
        scheduled_at: DateTime.add(until, @slack_seconds, :second),
        unique: [period: :infinity, fields: [:worker, :args], states: [:scheduled, :available]]
      )

    # A deduped insert returns {:ok, %Oban.Job{conflict?: true}} rather than an
    # error: the wait is already recorded, so nothing more is emitted. This
    # branch cannot be regression-tested here: config/test.exs sets
    # `engine: false`, so Jobs.insert/1 always falls through to its
    # Repo.insert/1 rescue clause, which never sets conflict?: true (the same
    # reason Mydia.Search.insert_jobs/2 gives).
    case Mydia.Jobs.insert(changeset) do
      {:ok, %Oban.Job{conflict?: true}} ->
        Logger.debug("Grab-delay re-check already scheduled", worker: inspect(worker))

      {:ok, _job} ->
        record_deferral(media_item, event_metadata, until, event_opts)

      {:error, reason} ->
        Logger.warning("Failed to schedule grab-delay re-check",
          worker: inspect(worker),
          args: recheck_args,
          reason: inspect(reason)
        )

        record_deferral(media_item, event_metadata, until, event_opts)
    end

    :ok
  end

  @doc """
  The args of the grab-delay re-checks still waiting to run for `worker`.

  Cron searches use this to leave a waiting item alone until its re-check
  fires: searching during the wait cannot grab anything.
  """
  @spec pending_rechecks(module()) :: [map()]
  def pending_rechecks(worker) do
    Oban.Job
    |> where([j], j.worker == ^inspect(worker) and j.state == "scheduled")
    |> select([j], j.args)
    |> Mydia.Repo.all()
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "recheck") == true))
  end

  defp record_deferral(media_item, event_metadata, until, event_opts) do
    Logger.info("Holding automatic grab until the grab delay passes",
      media_item_id: media_item.id,
      title: media_item.title,
      result_title: Map.get(event_metadata, "selected_release"),
      grab_after: until
    )

    Events.search_deferred(
      media_item,
      Map.put(event_metadata, "grab_after", DateTime.to_iso8601(until)),
      event_opts
    )
  end
end
