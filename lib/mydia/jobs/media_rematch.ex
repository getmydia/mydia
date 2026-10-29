defmodule Mydia.Jobs.MediaRematch do
  @moduledoc """
  Background job that applies a post-import re-match.

  Moves an already-imported file to the correct library location, re-links its
  `MediaFile` to the corrected media item / episode, and re-notifies media
  servers. The target was already persisted on the download row by
  `Mydia.Downloads.Queue.rematch_imported_download/3` before this job was
  enqueued; this job carries out the filesystem + DB reconciliation.

  ## Safety ordering

  Ecto has no filesystem transaction, so the sequence is built to never leave the
  DB pointing at a missing file and never let a racing `LibraryScanner` strand a
  duplicate:

    1. Copy / hardlink the file to the destination (never `rename`), verifying
       size; the source is kept until after the commit.
    2. In one `Repo.transaction`: re-read the source row and abort if it was
       trashed or its path drifted; adopt any duplicate row a concurrent scan
       created at the destination; relink the row (parent-flip) and stamp
       provenance.
    3. Only after the commit, delete the source.

  Re-match is move-optional: when the file is already at the computed
  destination, only the DB relink runs. Idempotent on retry.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [
      period: :infinity,
      keys: [:download_id],
      states: [:suspended, :available, :scheduled, :retryable, :executing]
    ]

  require Logger

  alias Mydia.{Downloads, Library}
  alias Mydia.Jobs.MediaImport
  alias Mydia.Library.{FileMove, MediaFile}
  alias Mydia.MediaServer.Notifier, as: MediaServerNotifier

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"download_id" => download_id}}) do
    case fetch_download(download_id) do
      nil ->
        Logger.info("Re-match short-circuit: download row no longer exists",
          download_id: download_id
        )

        :ok

      download ->
        run(download)
    end
  end

  defp fetch_download(download_id) do
    Downloads.get_download(download_id,
      preload: [:media_item, :episode, :library_path]
    )
  end

  defp run(download) do
    with :ok <- validate_rematchable(download),
         {:ok, media_file} <- locate_file(download),
         {:ok, library_path} <- resolve_destination(download),
         {dest_path, new_rel} <- compute_destination(download, media_file, library_path),
         {:ok, placed} <- FileMove.place(media_file, dest_path, library_path),
         {:ok, _updated} <- relink(download, media_file, library_path, new_rel, placed) do
      # Commit succeeded — now it is safe to remove the source path.
      cleanup_source(download, media_file, dest_path)
      MediaServerNotifier.notify_all(path: dest_path)
      Downloads.broadcast_download_update(download.id)

      Logger.info("Re-match complete", download_id: download.id, dest: dest_path)
      {:ok, :rematched}
    else
      {:error, reason} ->
        Logger.error("Re-match failed", download_id: download.id, reason: inspect(reason))
        mark_failed(download, reason)
        {:error, reason}
    end
  end

  defp validate_rematchable(download) do
    cond do
      is_nil(download.imported_at) -> {:error, :not_imported}
      not is_nil(download.match_status) -> {:error, :not_single_target}
      true -> :ok
    end
  end

  defp locate_file(download) do
    case Library.list_media_files_for_download(download, preload: [:library_path]) do
      [%MediaFile{} = file] -> {:ok, file}
      [] -> {:error, :no_imported_file}
      _multiple -> {:error, :multiple_files}
    end
  end

  defp resolve_destination(download) do
    case MediaImport.determine_library_path(download) do
      nil -> {:error, :no_library_path}
      library_path -> {:ok, library_path}
    end
  end

  defp compute_destination(download, media_file, library_path) do
    dest_dir = MediaImport.build_destination_path(download, library_path)
    original = Path.basename(media_file.relative_path)
    rename? = library_path.auto_rename || false
    filename = MediaImport.generate_filename(download, download.episode, original, rename?)
    dest_path = Path.join(dest_dir, filename)
    new_rel = Path.relative_to(dest_path, library_path.path)
    {dest_path, new_rel}
  end

  defp relink(download, media_file, library_path, new_rel, placed) do
    stamp = fn _updated -> stamp_provenance_or_skip(download, media_file) end
    FileMove.relink(media_file, library_path, new_rel, parent_attrs(download), stamp, placed)
  end

  defp parent_attrs(%{episode_id: nil} = download),
    do: %{media_item_id: download.media_item_id, episode_id: nil}

  defp parent_attrs(download), do: %{episode_id: download.episode_id, media_item_id: nil}

  # Provenance is part of the re-match contract; a failed stamp rolls back the
  # relink so callers can retry rather than half-update.
  #
  # One exception: the download row being gone. The stamp is an audit trail,
  # and there is nothing left to attach it to. Rolling back would discard a
  # correct, disk-verified relink over bookkeeping, and since the row stays
  # gone every retry fails identically until the job is discarded, leaving the
  # media file permanently mis-linked (issue #285).
  defp stamp_provenance_or_skip(download, old_media_file) do
    case stamp_provenance(download, old_media_file) do
      {:ok, _} = ok ->
        ok

      {:error, changeset} ->
        if Downloads.stale_changeset?(changeset) do
          Logger.info("Download row removed before provenance stamp; keeping the relink",
            download_id: download.id
          )

          {:ok, :skipped}
        else
          {:error, {:provenance_failed, changeset}}
        end
    end
  end

  defp stamp_provenance(download, old_media_file) do
    metadata = download.metadata || %{}

    stamped =
      metadata
      |> Map.put("rematched_from_media_item_id", old_media_file.media_item_id)
      |> Map.put("rematched_from_episode_id", old_media_file.episode_id)
      |> Map.put("rematched_at", DateTime.utc_now() |> DateTime.to_iso8601())

    Downloads.update_download(download, %{metadata: stamped})
  end

  defp cleanup_source(download, media_file, dest_path) do
    source_path = MediaFile.storage_path(media_file)

    case FileMove.cleanup_source(source_path, dest_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Re-match source delete failed; recording for cleanup sweep",
          source: source_path,
          reason: inspect(reason)
        )

        # Record the pending path so a retry's idempotent short-circuit doesn't
        # strand the orphan (a later sweep removes it). Best-effort.
        record_pending_source_delete(download.id, source_path)
    end
  end

  defp record_pending_source_delete(download_id, source_path) do
    case Downloads.get_download(download_id) do
      nil ->
        :ok

      download ->
        metadata = Map.put(download.metadata || %{}, "rematch_pending_source_delete", source_path)
        Downloads.update_download(download, %{metadata: metadata})
    end
  rescue
    # Best-effort bookkeeping: the reload's missing-row case is handled above,
    # but this must never take down a re-match that otherwise succeeded.
    _ -> :ok
  end

  defp mark_failed(download, reason) do
    Downloads.update_download(download, %{
      import_failed_at: DateTime.utc_now(),
      import_last_error: "re-match failed: #{inspect(reason)}"
    })

    Downloads.broadcast_download_update(download.id)
  end
end
