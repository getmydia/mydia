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

    case Mydia.Jobs.insert(changeset) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to schedule grab-delay re-check",
          worker: inspect(worker),
          args: recheck_args,
          reason: inspect(reason)
        )
    end

    Events.search_deferred(
      media_item,
      Map.put(event_metadata, "grab_after", DateTime.to_iso8601(until)),
      event_opts
    )

    :ok
  end
end
