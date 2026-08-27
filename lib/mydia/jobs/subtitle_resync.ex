defmodule Mydia.Jobs.SubtitleResync do
  @moduledoc """
  Computes and stores the timing offset for one subtitle track.

  Runs on the dedicated `:subsync` queue at concurrency 1. That concurrency is
  the throttle for the whole feature: decoding a film's audio is CPU heavy, and
  on a small home server it must never compete with library scanning or
  streaming.

  A media file that no longer exists is a success rather than a failure. There
  is nothing to re-sync and nothing to retry. The same applies to a
  `media_file_id` that is not even a well-formed UUID: nothing enqueues that
  today, but a `phx-value` on a client-facing control is forgeable, and
  `Repo.get/2` would otherwise raise `Ecto.Query.CastError` and burn all three
  attempts against a value that can never resolve.
  """

  use Oban.Worker,
    queue: :subsync,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:worker, :args],
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias Mydia.Library
  alias Mydia.Subtitles.Resync

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: %{"media_file_id" => media_file_id, "track_ref" => track_ref}}) do
    case Ecto.UUID.cast(media_file_id) do
      :error -> :ok
      {:ok, _uuid} -> resync(media_file_id, track_ref)
    end
  end

  defp resync(media_file_id, track_ref) do
    case Library.get_media_file(media_file_id, preload: [:library_path]) do
      nil ->
        :ok

      media_file ->
        case Resync.run(media_file, track_ref) do
          {:ok, offset_ms} ->
            Logger.info("Subtitle re-sync stored an offset",
              media_file_id: media_file_id,
              track_ref: track_ref,
              offset_ms: offset_ms
            )

          {:skip, reason} ->
            Logger.debug("Subtitle re-sync declined",
              media_file_id: media_file_id,
              track_ref: track_ref,
              reason: reason
            )

          {:error, reason} ->
            Logger.warning("Subtitle re-sync failed",
              media_file_id: media_file_id,
              track_ref: track_ref,
              reason: inspect(reason)
            )
        end

        :ok
    end
  end
end
