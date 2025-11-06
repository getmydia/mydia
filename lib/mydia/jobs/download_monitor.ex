defmodule Mydia.Jobs.DownloadMonitor do
  @moduledoc """
  Background job for monitoring downloads and handling completion.

  With download clients as the source of truth, this job now focuses on:
  - Detecting completed downloads in clients
  - Marking downloads as completed in the database
  - Triggering media import jobs for completed downloads
  - Recording errors for failed downloads
  - Cleaning up downloads that were removed from clients

  ## Missing Download Detection

  When a download is manually removed from a download client (e.g., Transmission),
  the job will detect this and automatically remove the download record from the
  database. This ensures media items don't remain stuck with "downloading" status.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5

  require Logger
  alias Mydia.Downloads
  alias Mydia.Downloads.UntrackedMatcher
  alias Mydia.Events

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Starting download completion monitoring", args: args)

    # Get all downloads with their real-time status from clients
    downloads = Downloads.list_downloads_with_status(filter: :all)

    # Find downloads that have completed or failed
    # Note: "seeding" means download is complete and now seeding (100% progress)
    # We check db_completed_at to see if we've already marked it as completed in our database
    completed =
      Enum.filter(downloads, fn d ->
        d.status in ["completed", "seeding"] and is_nil(d.db_completed_at)
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

    duration = System.monotonic_time(:millisecond) - start_time

    Logger.info("Download monitoring completed",
      duration_ms: duration,
      completed_count: length(completed),
      failed_count: length(failed),
      missing_count: length(missing),
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

    # Mark download as completed in database (prevents reprocessing on next monitor run)
    {:ok, download} = Downloads.mark_download_completed(download)

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
    Logger.info("Handling missing download (removed from client)",
      download_id: download_map.id,
      title: download_map.title,
      client: download_map.download_client
    )

    # Get the download struct from database
    download = Downloads.get_download!(download_map.id)

    # Delete the download record since it no longer exists in any client
    # This prevents the media item from showing as "downloading"
    case Downloads.delete_download(download) do
      {:ok, _deleted} ->
        Logger.info("Download removed from database (no longer in client)",
          download_id: download_map.id
        )

        # TODO: Emit download.removed event when events system exists (task-107)
        :ok

      {:error, changeset} ->
        Logger.error("Failed to delete missing download",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  defp enqueue_import_job(download, download_map) do
    %{
      "download_id" => download.id,
      "save_path" => download_map.save_path,
      "cleanup_client" => true,
      "move_files" => false
    }
    |> Mydia.Jobs.MediaImport.new()
    |> Oban.insert()
  end
end
