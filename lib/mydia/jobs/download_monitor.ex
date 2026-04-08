defmodule Mydia.Jobs.DownloadMonitor do
  @moduledoc """
  Background job for monitoring downloads and handling completion.

  With download clients as the source of truth, this job now focuses on:
  - Detecting completed downloads in clients
  - Marking downloads as completed in the database
  - Triggering media import jobs for completed downloads
  - Recording errors for failed downloads
  - Flagging downloads that were removed from clients

  ## Missing Download Detection

  When a download is manually removed from a download client (e.g., Transmission),
  the job will detect this and mark the download as "missing" with an error message.
  This preserves the download in the Issues tab so users can investigate why the
  download was removed before import completed. Users can manually delete from
  the Issues tab if desired.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5

  require Logger
  alias Mydia.Downloads
  alias Mydia.Downloads.UntrackedMatcher
  alias Mydia.Events

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Starting download completion monitoring", args: args)

    # Get all downloads with their real-time status from clients
    downloads = Downloads.list_downloads_with_status(filter: :all)

    # Find downloads that have completed or failed
    # Note: "seeding" means download is complete and now seeding (100% progress)
    # A torrent can also be paused at 100% progress (manually paused after completion)
    # We check db_completed_at to see if we've already marked it as completed in our database
    completed =
      Enum.filter(downloads, fn d ->
        is_nil(d.db_completed_at) and
          (d.status in ["completed", "seeding"] or
             (d.status == "paused" and d.progress == 100.0))
      end)

    failed = Enum.filter(downloads, &(&1.status == "failed" and is_nil(&1.error_message)))

    # Find downloads that no longer exist in any tracker
    # These are downloads that were manually removed from the client
    # Status is "missing" when download exists in DB but not in any client
    missing =
      Enum.filter(downloads, fn d ->
        d.status == "missing" and is_nil(d.db_completed_at) and is_nil(d.error_message)
      end)

    Logger.info(
      "Found #{length(completed)} newly completed, #{length(failed)} newly failed, #{length(missing)} missing downloads"
    )

    # Handle completions
    Enum.each(completed, &handle_completion/1)

    # Handle failures
    Enum.each(failed, &handle_failure/1)

    # Handle missing downloads
    Enum.each(missing, &handle_missing/1)

    # Find and match untracked torrents (manually added to clients)
    untracked_downloads = UntrackedMatcher.find_and_match_untracked()
    Logger.info("Matched #{length(untracked_downloads)} untracked torrent(s) to library items")

    # Detect stuck downloads (completed but never imported for >1 hour)
    stuck = Downloads.list_stuck_downloads(preload: [:media_item])
    Logger.info("Found #{length(stuck)} stuck downloads")
    Enum.each(stuck, &handle_stuck/1)

    duration = System.monotonic_time(:millisecond) - start_time

    Logger.info("Download monitoring completed",
      duration_ms: duration,
      completed_count: length(completed),
      failed_count: length(failed),
      missing_count: length(missing),
      stuck_count: length(stuck),
      untracked_matched: length(untracked_downloads)
    )

    :ok
  end

  ## Private Functions

  defp handle_completion(download_map) do
    Logger.info("Handling completed download",
      download_id: download_map.id,
      title: download_map.title,
      save_path: download_map.save_path
    )

    # Get the download struct from database (with media_item preloaded)
    download = Downloads.get_download!(download_map.id, preload: [:media_item])

    # Mark download as completed and persist save_path from client
    # (save_path is critical for Usenet imports where items leave client history fast)
    {:ok, download} = Downloads.mark_download_completed(download)

    {:ok, download} =
      if download_map.save_path do
        Downloads.update_download(download, %{save_path: download_map.save_path})
      else
        {:ok, download}
      end

    # Track completion event
    Events.download_completed(download, media_item: download.media_item)

    # Enqueue import job - it will delete the download record after successful import
    case enqueue_import_job(download, download_map) do
      {:ok, _job} ->
        Logger.info("Import job enqueued for completed download",
          download_id: download.id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to enqueue import job",
          download_id: download.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp handle_failure(download_map) do
    Logger.info("Handling failed download",
      download_id: download_map.id,
      title: download_map.title,
      error: download_map.error_message
    )

    # Get the download struct from database (with media_item preloaded)
    download = Downloads.get_download!(download_map.id, preload: [:media_item])

    error_msg = download_map.error_message || "Download failed in client"

    # Track failure event before deletion
    Events.download_failed(download, error_msg, media_item: download.media_item)

    # Delete the download record - downloads table is ephemeral
    case Downloads.delete_download(download) do
      {:ok, _deleted} ->
        Logger.info("Download removed from queue (failed)",
          download_id: download_map.id,
          error: error_msg
        )

        :ok

      {:error, changeset} ->
        Logger.error("Failed to delete failed download",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  defp handle_missing(download_map) do
    Logger.warning("Download missing from client - preserving for user investigation",
      download_id: download_map.id,
      title: download_map.title,
      client: download_map.download_client
    )

    # Get the download struct from database (with media_item preloaded)
    download = Downloads.get_download!(download_map.id, preload: [:media_item])

    # Instead of deleting, mark as missing with error message
    # This preserves the record in the Issues tab for user investigation
    error_msg =
      "Removed from download client '#{download_map.download_client}' before import completed. " <>
        "The download may have been manually deleted, or the client may have encountered an error."

    case Downloads.update_download(download, %{
           status: "missing",
           error_message: error_msg
         }) do
      {:ok, updated} ->
        Logger.info("Download marked as missing (preserved for Issues tab)",
          download_id: download_map.id,
          status: updated.status
        )

        # Track event for user visibility
        Events.download_failed(download, error_msg, media_item: download.media_item)
        :ok

      {:error, changeset} ->
        Logger.error("Failed to mark download as missing",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  defp handle_stuck(download) do
    # Calculate how long the download has been stuck
    hours_stuck =
      DateTime.diff(DateTime.utc_now(), download.completed_at, :hour)

    Logger.warning("Download stuck - completed but never imported",
      download_id: download.id,
      title: download.title,
      completed_at: download.completed_at,
      hours_stuck: hours_stuck
    )

    error_msg =
      "Import stalled - download completed #{hours_stuck} hour(s) ago but import never ran. " <>
        "This may indicate the import job failed silently or was never scheduled. " <>
        "A new import will be attempted automatically."

    # Flag as failed so it appears in Issues tab
    case Downloads.update_download(download, %{
           import_failed_at: DateTime.utc_now(),
           import_last_error: error_msg
         }) do
      {:ok, updated} ->
        Logger.info("Stuck download flagged for investigation",
          download_id: download.id
        )

        # Track event for user visibility
        Events.download_failed(download, error_msg, media_item: download.media_item)

        # Enqueue a new import job to retry
        enqueue_import_job(updated)

      {:error, changeset} ->
        Logger.error("Failed to flag stuck download",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )
    end
  end

  # Enqueue import job with save_path from client status (normal completion flow)
  defp enqueue_import_job(download, download_map) do
    %{
      "download_id" => download.id,
      "save_path" => download_map.save_path,
      "cleanup_client" => true,
      "use_hardlinks" => true,
      "move_files" => false
    }
    |> Mydia.Jobs.MediaImport.new()
    |> Oban.insert()
  end

  # Enqueue import job for stuck downloads (use persisted save_path when available)
  defp enqueue_import_job(download) do
    args =
      %{
        "download_id" => download.id,
        "cleanup_client" => true,
        "use_hardlinks" => true,
        "move_files" => false
      }
      |> maybe_add_save_path(download.save_path)

    changeset = Mydia.Jobs.MediaImport.new(args)

    # Use Oban.insert if available, otherwise fall back to Repo.insert for testing
    result =
      try do
        Oban.insert(changeset)
      rescue
        RuntimeError ->
          # In testing mode without running Oban, insert directly via Repo
          Mydia.Repo.insert(changeset)
      end

    case result do
      {:ok, job} ->
        Logger.info("Retry import job enqueued for stuck download",
          download_id: download.id,
          job_id: job.id
        )

        {:ok, job}

      {:error, reason} = error ->
        Logger.error("Failed to enqueue retry import job",
          download_id: download.id,
          reason: inspect(reason)
        )

        error
    end
  end

  defp maybe_add_save_path(args, nil), do: args
  defp maybe_add_save_path(args, ""), do: args
  defp maybe_add_save_path(args, save_path), do: Map.put(args, "save_path", save_path)
end
