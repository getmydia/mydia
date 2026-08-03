defmodule Mydia.Jobs.SegmentDetectionScheduler do
  @moduledoc """
  Cron worker that finds seasons needing segment detection and enqueues one
  job each.

  Detection is season-scoped but its state is tracked per file, so this worker
  translates "files needing work" into "seasons to process". There is no
  `seasons` table: a season is the tuple `(media_item_id, season_number)`
  derived from `episodes`.

  A file is only eligible once `FileAnalysis` has given it a duration, because
  both fingerprint windows are computed from runtime. Waiting for that is an
  ordering dependency between the two workers rather than a failure, so a file
  without one is not selected, stays `pending`, and spends no attempt.

  When `fpcalc` is absent this enqueues nothing at all. Availability is a
  runtime capability check, never a persisted state, so installing chromaprint
  later needs no data repair: the backlog of `pending` files is picked up on
  the next tick.
  """

  use Oban.Worker,
    queue: :segments,
    max_attempts: 1,
    # Matches FileAnalysis. A tick that overruns the 5-minute schedule would
    # otherwise have a second tick select the same seasons behind it.
    unique: [
      period: 300,
      fields: [:worker],
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  require Logger

  alias Mydia.Jobs.SegmentDetection, as: SegmentDetectionJob
  alias Mydia.Library.MediaFile
  alias Mydia.Library.SegmentDetection
  alias Mydia.Library.SegmentDetection.Fingerprint
  alias Mydia.Media.Episode
  alias Mydia.Repo

  # The segments queue runs at concurrency 1, so a tick that queued the whole
  # library would just build a backlog the next tick cannot see past. Bounding
  # it keeps the queue short and the ordering stable.
  @seasons_per_tick 20

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    if Fingerprint.available?() do
      enqueue_pending_seasons()
    else
      # Debug rather than info: this ticks every 5 minutes, and an operator
      # without chromaprint installed should not have their logs filled with
      # it. The admin UI surfaces the same capability check where it is useful.
      Logger.debug("Skipping segment detection: audio fingerprinting is unavailable")
      :ok
    end
  end

  @doc """
  Seasons with at least one file waiting on detection, as
  `{media_item_id, season_number}` tuples.
  """
  @spec pending_seasons() :: [{binary(), integer()}]
  def pending_seasons do
    max_attempts = SegmentDetection.max_attempts()

    Repo.all(
      from(mf in MediaFile,
        join: e in Episode,
        on: e.id == mf.episode_id,
        where:
          mf.segment_analysis_state == "pending" and
            mf.segment_analysis_attempts < ^max_attempts and
            not is_nil(mf.analyzed_at) and is_nil(mf.trashed_at),
        group_by: [e.media_item_id, e.season_number],
        order_by: [asc: e.media_item_id, asc: e.season_number],
        limit: @seasons_per_tick,
        select: {e.media_item_id, e.season_number}
      )
    )
  end

  defp enqueue_pending_seasons do
    seasons = pending_seasons()

    if seasons != [] do
      Logger.debug("Enqueueing segment detection", seasons: length(seasons))
    end

    # IMPORTANT: enqueue one at a time with Oban.insert/1.
    #
    # Oban.insert_all/1 silently bypasses the worker's `unique:` option on the
    # Basic and Lite engines this project runs, so a slow season would collect
    # a duplicate job on every tick. The app disables Oban's engine entirely
    # under test (`engine: false`), where uniqueness does not apply either, so
    # nothing in the default test setup would flag the regression.
    # Do not "optimize" this into insert_all.
    Enum.each(seasons, &enqueue_season/1)

    :ok
  end

  defp enqueue_season({media_item_id, season_number}) do
    %{media_item_id: media_item_id, season_number: season_number}
    |> SegmentDetectionJob.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue segment detection",
          media_item_id: media_item_id,
          season_number: season_number,
          reason: inspect(reason)
        )

        :error
    end
  end
end
