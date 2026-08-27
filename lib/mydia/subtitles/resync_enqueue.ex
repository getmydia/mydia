defmodule Mydia.Subtitles.ResyncEnqueue do
  @moduledoc """
  Enqueues `Mydia.Jobs.SubtitleResync` for a subtitle track that just arrived.

  Shared by `Mydia.Subtitles.Downloader` (provider downloads) and
  `Mydia.Subtitles.Sidecars` (files adopted from disk), because a subtitle
  that has just arrived is the highest-value moment to check its timing: a
  provider subtitle cut for a different release is the single most common
  source of desync, and a sidecar someone dropped on disk has never been
  checked at all.
  """

  require Logger

  alias Mydia.Jobs.SubtitleResync

  @doc """
  Enqueues a re-sync job for `media_file_id`/`track_ref`.

  Enqueued one at a time with `Oban.insert/1`. `Oban.insert_all/1` silently
  bypasses the worker's `unique:` option on the Basic and Lite engines this
  project runs, so a re-reconciled directory or a re-downloaded subtitle
  would collect a duplicate job per pass. Do not "optimize" this into
  insert_all.

  A failed enqueue is logged and swallowed rather than returned as an error:
  the subtitle row is already written, and the download or adoption that
  triggered this must not fail because the queue did. The `rescue` clause is
  load-bearing, not defensive dead code: `Oban.insert/1` raises rather than
  returning an error tuple when no Oban instance is running, which is most of
  this application's own test suite (Oban is skipped from the supervision
  tree under `testing: :manual`/`engine: false`), so any test that adopts a
  sidecar or downloads a subtitle without starting its own Oban instance
  would otherwise fail here. Matches the same guard
  `Mydia.Jobs.HdrBackfill.enqueue_once/0` already uses around its own
  `Oban.insert/1` call at boot.
  """
  @spec enqueue(binary(), String.t()) :: :ok | :error
  def enqueue(media_file_id, track_ref) do
    %{media_file_id: media_file_id, track_ref: track_ref}
    |> SubtitleResync.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue subtitle re-sync",
          media_file_id: media_file_id,
          track_ref: track_ref,
          reason: inspect(reason)
        )

        :error
    end
  rescue
    error ->
      Logger.warning("Failed to enqueue subtitle re-sync",
        media_file_id: media_file_id,
        track_ref: track_ref,
        reason: inspect(error)
      )

      :error
  end
end
