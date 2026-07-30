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

  alias Mydia.{Downloads, Library, Repo}
  alias Mydia.Jobs.MediaImport
  alias Mydia.Library.{FileOrganizer, MediaFile}
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
    Downloads.get_download!(download_id,
      preload: [:media_item, :episode, :library_path]
    )
  rescue
    Ecto.NoResultsError -> nil
  end

  defp run(download) do
    with :ok <- validate_rematchable(download),
         {:ok, media_file} <- locate_file(download),
         {:ok, library_path} <- resolve_destination(download),
         {dest_path, new_rel} <- compute_destination(download, media_file, library_path),
         {:ok, _action} <- place(media_file, library_path, dest_path, new_rel),
         {:ok, _updated} <- relink(download, media_file, library_path, new_rel) do
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

  defp place(media_file, library_path, dest_path, _new_rel) do
    source_path = MediaFile.absolute_path(media_file)

    cond do
      is_nil(source_path) ->
        {:error, :no_source_path}

      not File.exists?(source_path) and not File.exists?(dest_path) ->
        {:error, :source_missing}

      true ->
        # fallback: :copy (never rename) keeps the source until after the commit.
        FileOrganizer.place_file(source_path, dest_path,
          use_hardlinks: true,
          fallback: :copy,
          confine_to: library_path.path,
          expected_size: media_file.size
        )
    end
  end

  defp relink(download, media_file, library_path, new_rel) do
    Repo.transaction(fn ->
      current = Repo.get(MediaFile, media_file.id)

      cond do
        is_nil(current) -> Repo.rollback(:media_file_gone)
        not is_nil(current.trashed_at) -> Repo.rollback(:media_file_trashed)
        path_drifted?(current, media_file) -> Repo.rollback(:media_file_moved)
        true -> apply_relink(download, current, media_file, library_path, new_rel)
      end
    end)
  end

  defp path_drifted?(current, snapshot) do
    current.relative_path != snapshot.relative_path or
      current.library_path_id != snapshot.library_path_id
  end

  defp apply_relink(download, current, old_media_file, library_path, new_rel) do
    # A racing scan may have created a row at the destination path; adopt it
    # (delete the duplicate) so we do not leave two rows for one file.
    adopt_destination_duplicate(library_path.id, new_rel, current.id)

    parent =
      if download.episode_id do
        %{episode_id: download.episode_id, media_item_id: nil}
      else
        %{media_item_id: download.media_item_id, episode_id: nil}
      end

    attrs = Map.merge(%{relative_path: new_rel, library_path_id: library_path.id}, parent)

    case Library.update_media_file(current, attrs) do
      {:ok, updated} ->
        # Provenance is part of the re-match contract; a failed stamp must roll
        # back the relink so callers can retry rather than half-update.
        case stamp_provenance(download, old_media_file) do
          {:ok, _} -> updated
          {:error, changeset} -> Repo.rollback({:provenance_failed, changeset})
        end

      {:error, changeset} ->
        Repo.rollback({:relink_failed, changeset})
    end
  end

  defp adopt_destination_duplicate(library_path_id, relative_path, keep_id) do
    case Library.get_media_file_by_relative_path(library_path_id, relative_path,
           include_trashed: true
         ) do
      %MediaFile{id: ^keep_id} -> :ok
      %MediaFile{} = duplicate -> Repo.delete(duplicate)
      nil -> :ok
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
    source_path = MediaFile.absolute_path(media_file)

    if source_path && source_path != dest_path && File.exists?(source_path) do
      case File.rm(source_path) do
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
    else
      :ok
    end
  end

  defp record_pending_source_delete(download_id, source_path) do
    with %_{} = download <- Downloads.get_download!(download_id) do
      metadata = Map.put(download.metadata || %{}, "rematch_pending_source_delete", source_path)
      Downloads.update_download(download, %{metadata: metadata})
    end
  rescue
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
