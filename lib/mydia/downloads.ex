defmodule Mydia.Downloads do
  @moduledoc """
  The Downloads context handles download queue management.
  """

  alias Mydia.Downloads.Download
  alias Mydia.Downloads.TranscodeJob
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.Structs.EnrichedDownload
  alias Mydia.Indexers.SearchResult
  alias Mydia.Settings
  require Logger

  # ── Client Registration & Connection ──────────────────────────────────

  @doc """
  Registers all available download client adapters with the Registry.

  This should be called during application startup to ensure all client
  adapters are available for use.
  """
  @spec register_clients() :: :ok
  def register_clients do
    Logger.info("Registering download client adapters...")

    # Register available client adapters
    Registry.register(:qbittorrent, Mydia.Downloads.Client.QBittorrent)
    Registry.register(:transmission, Mydia.Downloads.Client.Transmission)
    Registry.register(:rqbit, Mydia.Downloads.Client.Rqbit)
    Registry.register(:rtorrent, Mydia.Downloads.Client.Rtorrent)
    Registry.register(:blackhole, Mydia.Downloads.Client.Blackhole)
    Registry.register(:sabnzbd, Mydia.Downloads.Client.Sabnzbd)
    Registry.register(:nzbget, Mydia.Downloads.Client.Nzbget)
    Registry.register(:debrid, Mydia.Downloads.Client.Debrid)

    Logger.info("Download client adapter registration complete")
    :ok
  end

  @doc """
  Tests the connection to a download client.

  Accepts either a DownloadClientConfig struct or a config map with the client
  connection details. Routes to the appropriate adapter based on the client type.

  ## Examples

      iex> config = %{type: :qbittorrent, host: "localhost", port: 8080, username: "admin", password: "pass"}
      iex> Mydia.Downloads.test_connection(config)
      {:ok, %ClientInfo{version: "v4.5.0", api_version: "2.8.19"}}

      iex> config = Settings.get_download_client_config!(id)
      iex> Mydia.Downloads.test_connection(config)
      {:ok, %ClientInfo{...}}
  """
  @spec test_connection(Settings.DownloadClientConfig.t() | map()) ::
          {:ok, Mydia.Downloads.Structs.ClientInfo.t()} | {:error, term()}
  def test_connection(%Settings.DownloadClientConfig{} = config) do
    adapter_config = config_to_map(config)
    test_connection(adapter_config)
  end

  def test_connection(%{type: type} = config) when is_atom(type) do
    with {:ok, adapter} <- Registry.get_adapter(type) do
      adapter.test_connection(config)
    end
  end

  # ── History (Download CRUD, queries, filtering) ───────────────────────

  @doc """
  Returns the list of downloads from the database.

  This returns minimal download records used for associations only.
  For real-time download state, use `list_downloads_with_status/1`.

  ## Options
    - `:media_item_id` - Filter by media item
    - `:episode_id` - Filter by episode
    - `:preload` - List of associations to preload
  """
  @spec list_downloads(keyword()) :: [Download.t()]
  defdelegate list_downloads(opts \\ []), to: Mydia.Downloads.History

  @doc """
  Returns the list of downloads enriched with real-time status from clients.

  This queries all configured download clients and enriches download records
  with current state (status, progress, speed, ETA, etc.).

  Returns a list of maps with merged database and client data.

  ## Options
    - `:filter` - Filter by status (:active, :completed, :failed, :all) - default :all
    - `:media_item_id` - Filter by media item
    - `:episode_id` - Filter by episode
  """
  @spec list_downloads_with_status(keyword()) :: [EnrichedDownload.t()]
  defdelegate list_downloads_with_status(opts \\ []), to: Mydia.Downloads.History

  @doc """
  Gets a single download.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the download does not exist.
  """
  @spec get_download!(binary(), keyword()) :: Download.t()
  defdelegate get_download!(id, opts \\ []), to: Mydia.Downloads.History

  @doc """
  Creates a download.
  """
  @spec create_download(map()) :: {:ok, Download.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_download(attrs \\ %{}), to: Mydia.Downloads.History

  @doc """
  Updates a download.
  """
  @spec update_download(Download.t(), map()) :: {:ok, Download.t()} | {:error, Ecto.Changeset.t()}
  defdelegate update_download(download, attrs), to: Mydia.Downloads.History

  @doc """
  Lists failed path-mapping-mismatch downloads whose reported path is at or under
  the given remote prefix (the apply-mapping fan-out set).
  """
  @spec list_path_mapping_mismatches_under_prefix(String.t()) :: [Download.t()]
  defdelegate list_path_mapping_mismatches_under_prefix(remote_prefix),
    to: Mydia.Downloads.History

  @doc """
  Lists distinct reported paths of downloads that failed import with a
  path-mapping mismatch. Useful as `remote_prefix` autocomplete suggestions.
  """
  @spec list_failed_remote_paths() :: [String.t()]
  defdelegate list_failed_remote_paths, to: Mydia.Downloads.History

  @doc """
  Marks a download as completed by storing the completion time.
  """
  @spec mark_download_completed(Download.t()) ::
          {:ok, Download.t()} | {:error, Ecto.Changeset.t()}
  defdelegate mark_download_completed(download), to: Mydia.Downloads.History

  @doc """
  Records an error message for a download.
  """
  @spec mark_download_failed(Download.t(), String.t()) ::
          {:ok, Download.t()} | {:error, Ecto.Changeset.t()}
  defdelegate mark_download_failed(download, error_message), to: Mydia.Downloads.History

  @doc """
  Deletes a download.
  """
  @spec delete_download(Download.t()) :: {:ok, Download.t()} | {:error, Ecto.Changeset.t()}
  defdelegate delete_download(download), to: Mydia.Downloads.History

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking download changes.
  """
  @spec change_download(Download.t(), map()) :: Ecto.Changeset.t()
  defdelegate change_download(download, attrs \\ %{}), to: Mydia.Downloads.History

  @doc """
  Gets all active downloads from clients (downloads currently in progress).

  This is now a convenience wrapper around list_downloads_with_status
  with filter: :active.
  """
  @spec list_active_downloads(keyword()) :: [EnrichedDownload.t()]
  defdelegate list_active_downloads(opts \\ []), to: Mydia.Downloads.History

  @doc """
  Counts active downloads (downloading, seeding, checking, paused).

  Returns the number of downloads currently in progress across all clients.
  """
  @spec count_active_downloads() :: non_neg_integer()
  defdelegate count_active_downloads(), to: Mydia.Downloads.History

  @doc """
  Lists "stuck" downloads that completed but never got imported.

  A download is considered stuck when:
  - `completed_at` is set (download finished)
  - `imported_at` is nil (not imported)
  - `import_failed_at` is nil (no tracked failure)
  - Completed more than the threshold ago (default: 1 hour)

  This catches edge cases where the import job never ran or silently failed.

  ## Options
    - `:threshold_minutes` - How long after completion to consider stuck (default: 60)
    - `:preload` - List of associations to preload

  ## Examples

      iex> list_stuck_downloads()
      [%Download{completed_at: ~U[...], imported_at: nil, import_failed_at: nil}]

      iex> list_stuck_downloads(threshold_minutes: 30)
      [%Download{...}]
  """
  @spec list_stuck_downloads(keyword()) :: [Download.t()]
  defdelegate list_stuck_downloads(opts \\ []), to: Mydia.Downloads.History

  @doc """
  Lists client-less grab records abandoned mid-flight (grab task died before
  writing an outcome) whose `inserted_at` is older than
  `Mydia.Downloads.History.grab_timeout_minutes/0`. See `History.list_stale_grabs/1`.
  """
  @spec list_stale_grabs(DateTime.t()) :: [Download.t()]
  defdelegate list_stale_grabs(now \\ DateTime.utc_now()), to: Mydia.Downloads.History

  @doc """
  The grab-timeout threshold (minutes). See `Mydia.Downloads.History.grab_timeout_minutes/0`.
  """
  @spec grab_timeout_minutes() :: pos_integer()
  defdelegate grab_timeout_minutes(), to: Mydia.Downloads.History

  @doc """
  Broadcasts a download update to all subscribed LiveViews.
  """
  @spec broadcast_download_update(binary()) :: :ok | {:error, term()}
  defdelegate broadcast_download_update(download_id), to: Mydia.Downloads.History

  # ── Queue (initiation, duplicate checking, cancellation) ──────────────

  @doc """
  Initiates a download from a search result.

  Selects download client, adds torrent, creates Download record.

  ## Arguments
    - search_result: %SearchResult{} with download_url
    - opts: Keyword list with:
      - :media_item_id - Associate with movie/show
      - :episode_id - Associate with episode
      - :client_name - Use specific client (otherwise priority)
      - :category - Client category for organization

  Returns {:ok, %Download{}} or {:error, reason}

  ## Examples

      iex> result = %SearchResult{download_url: "magnet:?xt=...", title: "Movie", ...}
      iex> initiate_download(result, media_item_id: movie_id)
      {:ok, %Download{}}

      iex> initiate_download(result, client_name: "qbittorrent-main")
      {:ok, %Download{}}
  """
  @spec initiate_download(SearchResult.t(), keyword()) :: {:ok, Download.t()} | {:error, term()}
  defdelegate initiate_download(search_result, opts \\ []), to: Mydia.Downloads.Queue

  @doc """
  Optimistically starts a download for a manual search result.

  Inserts the Download record synchronously (derived status `"grabbing"`) and
  returns immediately; the duplicate check, torrent fetch, and client handoff
  run in a supervised background task. Outcomes are broadcast on the
  `"downloads"` PubSub topic as `:grab_completed` / `:grab_failed` /
  `:grab_duplicate` messages.

  Returns `{:error, {:task_start_failed, reason}}` if the background task
  can't be started; the optimistic record is removed in that case.
  """
  @spec grab_async(SearchResult.t(), keyword()) ::
          {:ok, Download.t()} | {:error, Ecto.Changeset.t() | {:task_start_failed, term()}}
  defdelegate grab_async(search_result, opts \\ []), to: Mydia.Downloads.Grabber

  @doc """
  Cancels a download by removing it from the download client.

  This removes the torrent from the client and deletes the database record.
  Downloads table is ephemeral (active downloads only).

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :user
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
    - Other client-specific options
  """
  @spec cancel_download(Download.t(), keyword()) :: {:ok, Download.t()} | {:error, term()}
  defdelegate cancel_download(download, opts \\ []), to: Mydia.Downloads.Queue

  @doc """
  Pauses a download in the download client.

  This pauses the torrent in the client, stopping the download/upload activity.
  The database record remains unchanged.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :user
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
  """
  @spec pause_download(Download.t(), keyword()) :: {:ok, Download.t()} | {:error, term()}
  defdelegate pause_download(download, opts \\ []), to: Mydia.Downloads.Queue

  @doc """
  Resumes a paused download in the download client.

  This resumes the torrent in the client, restarting the download/upload activity.
  The database record remains unchanged.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :user
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
  """
  @spec resume_download(Download.t(), keyword()) :: {:ok, Download.t()} | {:error, term()}
  defdelegate resume_download(download, opts \\ []), to: Mydia.Downloads.Queue

  @doc """
  Clears a completed (imported) download.

  This removes the download from the client (always, since user explicitly requested)
  and deletes the Download record from the database.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :user
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
  """
  @spec clear_completed(Download.t(), keyword()) ::
          {:ok, Download.t()} | {:error, Ecto.Changeset.t()}
  defdelegate clear_completed(download, opts \\ []), to: Mydia.Downloads.Queue

  @doc """
  Clears all completed (imported) downloads.

  Returns the count of successfully cleared downloads.
  """
  @spec clear_all_completed(keyword()) :: {:ok, non_neg_integer()}
  defdelegate clear_all_completed(opts \\ []), to: Mydia.Downloads.Queue

  @doc """
  Counts imported downloads that `clear_all_completed/1` would clear.
  """
  @spec count_completed() :: non_neg_integer()
  defdelegate count_completed(), to: Mydia.Downloads.History

  @doc """
  Checks for duplicate downloads (active downloads or existing media files).
  """
  defdelegate check_for_duplicate_download(search_result, opts), to: Mydia.Downloads.Queue

  @doc """
  Checks if there's already an active download for the given media.
  """
  defdelegate check_for_active_download(search_result, media_item_id, episode_id),
    to: Mydia.Downloads.Queue

  @doc """
  Checks if media files already exist for the given media.
  """
  defdelegate check_for_existing_media_files(search_result, media_item_id, episode_id),
    to: Mydia.Downloads.Queue

  @doc """
  Manually matches an unmatched download to a media item, then triggers import.

  Sets the media_item_id (and optionally episode_id), clears match_status,
  and enqueues a MediaImport job.
  """
  defdelegate manually_match_download(download, media_item_id, episode_id \\ nil),
    to: Mydia.Downloads.Queue

  @doc """
  Refreshes match suggestions for an unmatched download by re-running TorrentMatcher.
  """
  defdelegate refresh_match_suggestions(download), to: Mydia.Downloads.Queue

  @doc """
  Resolves file-to-episode mappings for an unresolved download and triggers re-import.

  Accepts a list of `%{path: string, episode_id: binary_id}` mappings.
  """
  defdelegate resolve_file_mappings(download, mappings), to: Mydia.Downloads.Queue

  @doc """
  Re-matches an already-imported download to a corrected movie or episode,
  enqueuing a MediaRematch job to move + relink the file. See
  `Mydia.Downloads.Queue.rematch_imported_download/3` for return values.
  """
  defdelegate rematch_imported_download(download, media_item_id, episode_id \\ nil),
    to: Mydia.Downloads.Queue

  @doc """
  Dismisses (deletes) a download from the Issues tab.
  """
  defdelegate dismiss_download(download), to: Mydia.Downloads.Queue

  @doc """
  Bulk-dismisses failed/errored downloads that don't have special match_status.
  Only deletes downloads that have actually failed (error_message or import_failed_at set).
  """
  defdelegate dismiss_all_cancelled(), to: Mydia.Downloads.Queue

  # ── Transcoding (transcode job management) ────────────────────────────

  @doc """
  Gets or creates a transcode job for a media file and resolution.

  If a job already exists, returns it. Otherwise creates a new job with "pending" status.

  ## Examples

      iex> get_or_create_job(media_file_id, "1080p")
      {:ok, %TranscodeJob{status: "pending"}}
  """
  @spec get_or_create_job(binary(), String.t()) ::
          {:ok, TranscodeJob.t()} | {:error, Ecto.Changeset.t()}
  defdelegate get_or_create_job(media_file_id, resolution), to: Mydia.Downloads.Transcoding

  @doc """
  Gets a cached transcode for a media file and resolution.

  Returns the transcode job only if it's in "ready" status, nil otherwise.

  ## Examples

      iex> get_cached_transcode(media_file_id, "720p")
      %TranscodeJob{status: "ready", output_path: "/path/to/file"}

      iex> get_cached_transcode(media_file_id, "480p")
      nil
  """
  @spec get_cached_transcode(binary(), String.t()) :: TranscodeJob.t() | nil
  defdelegate get_cached_transcode(media_file_id, resolution), to: Mydia.Downloads.Transcoding

  @doc """
  Updates the progress of a transcode job.

  Also sets the status to "transcoding" and records the start time if not already set.

  ## Examples

      iex> update_job_progress(job, 0.5)
      {:ok, %TranscodeJob{progress: 0.5, status: "transcoding"}}
  """
  @spec update_job_progress(TranscodeJob.t(), float()) ::
          {:ok, TranscodeJob.t()} | {:error, Ecto.Changeset.t()}
  defdelegate update_job_progress(job, progress), to: Mydia.Downloads.Transcoding

  @doc """
  Marks a transcode job as complete.

  Sets status to "ready", records completion time, and stores output path and file size.

  ## Examples

      iex> complete_job(job, "/path/to/output.mp4", 1024000)
      {:ok, %TranscodeJob{status: "ready", completed_at: ~U[...]}}
  """
  @spec complete_job(TranscodeJob.t(), String.t(), non_neg_integer()) ::
          {:ok, TranscodeJob.t()} | {:error, Ecto.Changeset.t()}
  defdelegate complete_job(job, output_path, file_size), to: Mydia.Downloads.Transcoding

  @doc """
  Marks a transcode job as failed.

  Sets status to "failed" and records the error message.

  ## Examples

      iex> fail_job(job, "FFmpeg error: invalid codec")
      {:ok, %TranscodeJob{status: "failed", error: "FFmpeg error: invalid codec"}}
  """
  @spec fail_job(TranscodeJob.t(), String.t()) ::
          {:ok, TranscodeJob.t()} | {:error, Ecto.Changeset.t()}
  defdelegate fail_job(job, error_message), to: Mydia.Downloads.Transcoding

  @doc """
  Updates the last_accessed_at timestamp for a transcode job.

  Used to track usage for cache eviction purposes.

  ## Examples

      iex> touch_last_accessed(job)
      {:ok, %TranscodeJob{last_accessed_at: ~U[...]}}
  """
  @spec touch_last_accessed(TranscodeJob.t()) ::
          {:ok, TranscodeJob.t()} | {:error, Ecto.Changeset.t()}
  defdelegate touch_last_accessed(job), to: Mydia.Downloads.Transcoding

  @doc """
  Broadcasts a transcode job update to all subscribed LiveViews.
  """
  @spec broadcast_job_update(binary()) :: :ok | {:error, term()}
  defdelegate broadcast_job_update(job_id), to: Mydia.Downloads.Transcoding

  @doc """
  Lists transcode jobs for a specific media file.

  Returns all download-type transcode jobs regardless of status.
  """
  @spec list_transcode_jobs_for_media_file(binary()) :: [TranscodeJob.t()]
  defdelegate list_transcode_jobs_for_media_file(media_file_id), to: Mydia.Downloads.Transcoding

  @doc """
  Lists transcode jobs.

  ## Options
    - `:preload` - List of associations to preload
    - `:status` - List of status strings to filter by (e.g. ["pending", "transcoding"])
    - `:limit` - Maximum number of results to return
  """
  @spec list_transcode_jobs(keyword()) :: [TranscodeJob.t()]
  defdelegate list_transcode_jobs(opts \\ []), to: Mydia.Downloads.Transcoding

  @doc """
  Cancels a transcode job.
  """
  @spec cancel_transcode_job(TranscodeJob.t()) :: {:ok, TranscodeJob.t()}
  defdelegate cancel_transcode_job(job), to: Mydia.Downloads.Transcoding

  @doc """
  Deletes all completed (ready) and failed transcode jobs and their files.
  """
  @spec delete_all_completed_jobs() :: :ok
  defdelegate delete_all_completed_jobs(), to: Mydia.Downloads.Transcoding

  @doc """
  Deletes all streaming jobs.
  Should be called on startup to clean up zombie records.
  """
  @spec delete_all_streaming_jobs() :: {non_neg_integer(), nil | [term()]}
  defdelegate delete_all_streaming_jobs(), to: Mydia.Downloads.Transcoding

  # ── Private (shared helpers used by test_connection) ──────────────────

  defp config_to_map(config) do
    %{
      type: config.type,
      host: config.host,
      port: config.port,
      use_ssl: config.use_ssl,
      username: config.username,
      password: config.password,
      url_base: config.url_base,
      api_key: config.api_key,
      connection_settings: config.connection_settings || %{},
      options: config.connection_settings || %{}
    }
  end
end
