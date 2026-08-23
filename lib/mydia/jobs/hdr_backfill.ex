defmodule Mydia.Jobs.HdrBackfill do
  @moduledoc """
  One-shot worker that re-probes media files carrying a legacy HDR value.

  The `canonicalize_hdr_format` migration rewrote `hdr_format` from display
  strings to canonical atoms, but it could not recover the two Dolby Vision
  facts, which were never stored, nor tell HDR10+ from HDR10, which was never
  detected. Both need a fresh ffprobe.

  Selection is by row state, so the worker is idempotent: it takes rows whose
  `hdr_format` is set but which have never been stamped, and stamping
  `hdr_backfilled_at` is what removes a row from the set. Every outcome stamps,
  including failures, so a permanently unreadable file cannot spin forever.

  This writes the HDR columns directly rather than going through
  `Mydia.Library.apply_analysis/2`. That function refuses to write once
  `analyzed_at` is set, which is true of every row here, so it would be a
  silent no-op. Writing directly is also narrower: the backfill has no
  business touching `codec`, `resolution`, `metadata`, or `analysis_attempts`.

  A file whose path no longer resolves is stamped and logged. It is not an
  error: the library may have moved on since the migration ran.
  """

  use Oban.Worker,
    queue: :analysis,
    max_attempts: 3,
    # A batch takes longer than one tick would allow it to settle, so the
    # worker reschedules itself (see perform/1). :retryable guards against
    # cron-style pileup the same way Mydia.Jobs.FileAnalysis does: without it
    # a failed pass sitting in backoff would not block a duplicate insert.
    unique: [
      period: 300,
      fields: [:worker],
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  require Logger

  alias Mydia.Library.{FileAnalyzer, Hdr, MediaFile}
  alias Mydia.Repo

  @default_batch_size 50

  @doc """
  Enqueues the one-shot backfill job. Called once at boot.

  Deliberately never raises. `Mydia.Application.start/2` has no top-level
  rescue, and its two siblings that call into this same startup block
  protect themselves already: `Mydia.Library.DatabaseHealthCheck.run/0`'s
  own doc says it "should never raise exceptions to avoid blocking the
  application", and `Mydia.Library.StartupSync.sync_all/0` follows the same
  convention. A bare `Oban.insert/1` does not: `Oban.Registry.config/1`
  raises `RuntimeError` for a name with no registered instance (possible if
  `oban_children/1` ever returns `[]` for some config edge case, or this
  runs before Oban has finished starting), and a transient DB error at
  exactly this moment raises too. Losing the whole application to a
  backfill job that can safely run on the next boot instead is a bad trade,
  especially for a self-hosted operator with no easy way to diagnose a boot
  crash. Do not remove this rescue as a "simplification": that is precisely
  what would let this job take down startup again.
  """
  @spec enqueue_once() :: :ok
  def enqueue_once do
    %{} |> new() |> Oban.insert()
    :ok
  rescue
    error ->
      Logger.warning("HDR backfill: failed to enqueue on boot", error: inspect(error))
      :ok
  end

  @doc """
  Ids of media files pending an HDR backfill, oldest first, capped at `limit`.

  A row is pending when its `hdr_format` was set by the migration (so there is
  something worth re-probing) but it has never been stamped, and it is not
  trashed. The migration deliberately mapped every legacy "Dolby Vision"
  string to a provisional `:hdr10` rather than `nil`, precisely so this
  predicate is complete: nothing the migration touched slips past it silently.
  """
  @spec pending_ids(pos_integer()) :: [binary()]
  def pending_ids(limit) do
    MediaFile
    |> where([f], not is_nil(f.hdr_format))
    |> where([f], is_nil(f.hdr_backfilled_at))
    |> where([f], is_nil(f.trashed_at))
    |> order_by([f], asc: f.id)
    |> limit(^limit)
    |> select([f], f.id)
    |> Repo.all()
  end

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    batch_size = Application.get_env(:mydia, :hdr_backfill_batch_size, @default_batch_size)

    case pending_ids(batch_size) do
      [] ->
        Logger.info("HDR backfill complete, no rows pending")
        :ok

      ids ->
        Enum.each(ids, &backfill_one/1)

        # Reschedule until the set drains. Singular insert/1, not insert_all/1,
        # which bypasses the worker's unique constraint.
        %{} |> new(schedule_in: 5) |> Oban.insert()
        :ok
    end
  end

  defp backfill_one(id) do
    media_file = Repo.get(MediaFile, id) |> Repo.preload(:library_path)
    path = media_file && MediaFile.absolute_path(media_file)

    cond do
      is_nil(media_file) ->
        :ok

      is_nil(path) or not File.exists?(path) ->
        Logger.info("HDR backfill stamping missing file", file_id: id)
        stamp(id, [])

      true ->
        case FileAnalyzer.analyze(path) do
          {:ok, %{hdr: %Hdr{} = hdr}} ->
            stamp(id,
              hdr_format: hdr.base,
              dolby_vision_profile: hdr.dv_profile,
              dolby_vision_bl_compat_id: hdr.bl_compat_id
            )

          {:ok, _result} ->
            stamp(id, [])

          {:error, reason} ->
            Logger.warning("HDR backfill ffprobe failed",
              file_id: id,
              reason: inspect(reason)
            )

            stamp(id, [])
        end
    end
  end

  # Writes the HDR columns and the stamp in one statement. Every outcome
  # stamps, so a row leaves the pending set exactly once whether or not
  # ffprobe told us anything new. Nothing outside these four columns is
  # touched: no codec, resolution, metadata, or analysis_attempts.
  defp stamp(id, hdr_fields) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    set = Keyword.put(hdr_fields, :hdr_backfilled_at, now)

    from(f in MediaFile, where: f.id == ^id)
    |> Repo.update_all(set: set)

    :ok
  end
end
