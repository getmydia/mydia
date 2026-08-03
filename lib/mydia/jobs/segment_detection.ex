defmodule Mydia.Jobs.SegmentDetection do
  @moduledoc """
  Detects intro and credits segments for one season.

  Runs on the dedicated `:segments` queue at concurrency 1. That concurrency is
  the throttle for the whole feature: audio decoding is CPU heavy, and on a
  small home server it must never compete with library scanning or streaming.

  A season is the tuple `(media_item_id, season_number)`; there is no `seasons`
  table. A season that no longer exists is a success rather than a failure,
  because `analyze_season/2` finds no files and so has nothing to do.
  """

  use Oban.Worker,
    queue: :segments,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:worker, :args],
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias Mydia.Library.SegmentDetection

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: %{"media_item_id" => media_item_id, "season_number" => season}}) do
    Logger.debug("Detecting segments for season",
      media_item_id: media_item_id,
      season_number: season
    )

    SegmentDetection.analyze_season(media_item_id, season)
  end
end
