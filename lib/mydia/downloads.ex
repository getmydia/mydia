defmodule Mydia.Downloads do
  @moduledoc """
  The Downloads context handles download queue management.
  """

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers
  alias Mydia.Repo
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.Structs.DownloadMetadata
  alias Mydia.Downloads.Structs.EnrichedDownload
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.SearchResultMetadata
  alias Mydia.Settings
  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias Mydia.Events
  alias Phoenix.PubSub
  require Logger

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
    Registry.register(:rtorrent, Mydia.Downloads.Client.Rtorrent)
    Registry.register(:blackhole, Mydia.Downloads.Client.Blackhole)
    Registry.register(:sabnzbd, Mydia.Downloads.Client.Sabnzbd)
    Registry.register(:nzbget, Mydia.Downloads.Client.Nzbget)
    Registry.register(:http, Mydia.Downloads.Client.HTTP)

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
  def list_downloads(opts \\ []) do
    Download
    |> apply_download_filters(opts)
    |> maybe_preload(opts[:preload])
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

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
  def list_downloads_with_status(opts \\ []) do
    # Get all download records from database
    # Preload episode.media_item to get parent show info for episode downloads
    downloads = list_downloads(preload: [:media_item, episode: :media_item])

    # Get all configured download clients
    clients = get_configured_clients()

    if clients == [] do
      Logger.warning("No download clients configured")
      # Return downloads with empty status
      Enum.map(downloads, &enrich_download_with_empty_status/1)
    else
      # Get status from all clients
      client_statuses = fetch_all_client_statuses(clients)

      # Enrich downloads with client status
      downloads
      |> Enum.map(&enrich_download_with_status(&1, client_statuses))
      |> apply_status_filters(opts[:filter] || :all)
    end
  end

  @doc """
  Gets a single download.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the download does not exist.
  """
  @spec get_download!(binary(), keyword()) :: Download.t()
  def get_download!(id, opts \\ []) do
    Download
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Creates a download.
  """
  @spec create_download(map()) :: {:ok, Download.t()} | {:error, Ecto.Changeset.t()}
  def create_download(attrs \\ %{}) do
    result =
      %Download{}
      |> Download.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, download} ->
        broadcast_download_update(download.id)
        {:ok, download}

      error ->
        error
    end
  end

  @doc """
  Updates a download.
  """
  @spec update_download(Download.t(), map()) :: {:ok, Download.t()} | {:error, Ecto.Changeset.t()}
  def update_download(%Download{} = download, attrs) do
    result =
      download
      |> Download.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated_download} ->
        broadcast_download_update(updated_download.id)
        {:ok, updated_download}

      error ->
        error
    end
  end

  @doc """
  Marks a download as completed by storing the completion time.
  """
  @spec mark_download_completed(Download.t()) ::
          {:ok, Download.t()} | {:error, Ecto.Changeset.t()}
  def mark_download_completed(%Download{} = download) do
    download
    |> Download.changeset(%{completed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc """
  Records an error message for a download.
  """
  @spec mark_download_failed(Download.t(), String.t()) ::
          {:ok, Download.t()} | {:error, Ecto.Changeset.t()}
  def mark_download_failed(%Download{} = download, error_message) do
    download
    |> Download.changeset(%{error_message: error_message})
    |> Repo.update()
  end

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
  def cancel_download(%Download{} = download, opts \\ []) do
    with {:ok, client_config} <- find_client_config(download.download_client),
         {:ok, adapter} <- get_adapter_for_client(client_config),
         client_map_config = config_to_map(client_config),
         :ok <-
           Client.remove_download(adapter, client_map_config, download.download_client_id, opts),
         {:ok, _deleted} <- delete_download(download) do
      # Track event
      actor_type = Keyword.get(opts, :actor_type, :user)
      actor_id = Keyword.get(opts, :actor_id, "unknown")

      Events.download_cancelled(download, actor_type, actor_id)

      {:ok, download}
    else
      {:error, reason} ->
        Logger.warning("Failed to cancel download: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Pauses a download in the download client.

  This pauses the torrent in the client, stopping the download/upload activity.
  The database record remains unchanged.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :user
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
  """
  @spec pause_download(Download.t(), keyword()) :: {:ok, Download.t()} | {:error, term()}
  def pause_download(%Download{} = download, opts \\ []) do
    with {:ok, client_config} <- find_client_config(download.download_client),
         {:ok, adapter} <- get_adapter_for_client(client_config),
         client_map_config = config_to_map(client_config),
         :ok <- Client.pause_torrent(adapter, client_map_config, download.download_client_id) do
      # Track event
      actor_type = Keyword.get(opts, :actor_type, :user)
      actor_id = Keyword.get(opts, :actor_id, "unknown")

      Events.download_paused(download, actor_type, actor_id)

      broadcast_download_update(download.id)
      {:ok, download}
    else
      {:error, reason} ->
        Logger.warning("Failed to pause download in client: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Resumes a paused download in the download client.

  This resumes the torrent in the client, restarting the download/upload activity.
  The database record remains unchanged.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :user
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
  """
  @spec resume_download(Download.t(), keyword()) :: {:ok, Download.t()} | {:error, term()}
  def resume_download(%Download{} = download, opts \\ []) do
    with {:ok, client_config} <- find_client_config(download.download_client),
         {:ok, adapter} <- get_adapter_for_client(client_config),
         client_map_config = config_to_map(client_config),
         :ok <- Client.resume_torrent(adapter, client_map_config, download.download_client_id) do
      # Track event
      actor_type = Keyword.get(opts, :actor_type, :user)
      actor_id = Keyword.get(opts, :actor_id, "unknown")

      Events.download_resumed(download, actor_type, actor_id)

      broadcast_download_update(download.id)
      {:ok, download}
    else
      {:error, reason} ->
        Logger.warning("Failed to resume download in client: #{inspect(reason)}")
        {:error, reason}
    end
  end

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
  def clear_completed(%Download{} = download, opts \\ []) do
    # Try to remove from client first (ignore errors as may already be removed)
    case find_client_config(download.download_client) do
      {:ok, client_config} ->
        case get_adapter_for_client(client_config) do
          {:ok, adapter} ->
            client_map_config = config_to_map(client_config)

            # Attempt to remove from client, but don't fail if it's already gone
            case Client.remove_download(
                   adapter,
                   client_map_config,
                   download.download_client_id,
                   opts
                 ) do
              :ok ->
                Logger.info("Removed completed download from client",
                  download_id: download.id,
                  client: download.download_client
                )

              {:error, reason} ->
                Logger.debug("Could not remove from client (may already be removed)",
                  download_id: download.id,
                  reason: inspect(reason)
                )
            end

          {:error, _} ->
            Logger.debug("No adapter found for client", client: download.download_client)
        end

      {:error, _} ->
        Logger.debug("Client config not found", client: download.download_client)
    end

    # Always delete the database record
    case delete_download(download) do
      {:ok, deleted_download} ->
        # Track event
        actor_type = Keyword.get(opts, :actor_type, :user)
        actor_id = Keyword.get(opts, :actor_id, "unknown")

        Events.download_cleared(download, actor_type, actor_id)

        {:ok, deleted_download}

      error ->
        error
    end
  end

  @doc """
  Clears all completed (imported) downloads.

  Returns the count of successfully cleared downloads.
  """
  @spec clear_all_completed(keyword()) :: {:ok, non_neg_integer()}
  def clear_all_completed(opts \\ []) do
    # Get all imported downloads
    imported_downloads =
      Download
      |> where([d], not is_nil(d.imported_at))
      |> Repo.all()

    results =
      Enum.map(imported_downloads, fn download ->
        case clear_completed(download, opts) do
          {:ok, _} -> :ok
          {:error, _} -> :error
        end
      end)

    success_count = Enum.count(results, &(&1 == :ok))
    {:ok, success_count}
  end

  @doc """
  Deletes a download.
  """
  @spec delete_download(Download.t()) :: {:ok, Download.t()} | {:error, Ecto.Changeset.t()}
  def delete_download(%Download{} = download) do
    result = Repo.delete(download)

    case result do
      {:ok, deleted_download} ->
        broadcast_download_update(deleted_download.id)
        {:ok, deleted_download}

      error ->
        error
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking download changes.
  """
  @spec change_download(Download.t(), map()) :: Ecto.Changeset.t()
  def change_download(%Download{} = download, attrs \\ %{}) do
    Download.changeset(download, attrs)
  end

  @doc """
  Gets all active downloads from clients (downloads currently in progress).

  This is now a convenience wrapper around list_downloads_with_status
  with filter: :active.
  """
  @spec list_active_downloads(keyword()) :: [EnrichedDownload.t()]
  def list_active_downloads(opts \\ []) do
    list_downloads_with_status(Keyword.put(opts, :filter, :active))
  end

  @doc """
  Counts active downloads (downloading, seeding, checking, paused).

  Returns the number of downloads currently in progress across all clients.
  """
  @spec count_active_downloads() :: non_neg_integer()
  def count_active_downloads do
    list_active_downloads()
    |> length()
  end

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
  def list_stuck_downloads(opts \\ []) do
    threshold_minutes = Keyword.get(opts, :threshold_minutes, 60)
    threshold_time = DateTime.add(DateTime.utc_now(), -threshold_minutes, :minute)

    Download
    |> where([d], not is_nil(d.completed_at))
    |> where([d], is_nil(d.imported_at))
    |> where([d], is_nil(d.import_failed_at))
    |> where([d], d.completed_at < ^threshold_time)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

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
  def initiate_download(%SearchResult{} = search_result, opts \\ []) do
    # Use protocol from search result
    download_type = search_result.download_protocol
    Logger.info("Download protocol: #{inspect(download_type)} for #{search_result.title}")
    Logger.info("Full search_result struct: #{inspect(search_result, limit: :infinity)}")

    opts = Keyword.put(opts, :download_type, download_type)

    with :ok <- check_for_duplicate_download(search_result, opts),
         {:ok, client_config, client_id, detected_type} <-
           select_and_add_to_client(search_result, opts),
         {:ok, download} <-
           create_download_record_with_retry(search_result, client_config, client_id, opts) do
      # Use detected type as fallback if protocol wasn't set
      final_type = download_type || detected_type

      Logger.info(
        "Final download type: #{inspect(final_type)} (original: #{inspect(download_type)}, detected: #{inspect(detected_type)})"
      )

      # Track event
      actor_type = Keyword.get(opts, :actor_type, :system)
      actor_id = Keyword.get(opts, :actor_id, "downloads_context")

      # Get media_item for context if available (preloaded on download)
      download_with_media = Repo.preload(download, :media_item)

      Events.download_initiated(download_with_media, actor_type, actor_id,
        media_item: download_with_media.media_item
      )

      {:ok, download}
    else
      {:error, reason} = error ->
        Logger.warning("Failed to initiate download: #{inspect(reason)}")
        error
    end
  end

  ## Private Functions

  # Selects appropriate client and adds the download, with smart fallback if type is detected
  defp select_and_add_to_client(search_result, opts) do
    download_type = Keyword.get(opts, :download_type)

    # First, prepare the torrent/nzb input (download file if needed)
    # Pass the indexer name for authentication
    with {:ok, torrent_input_result} <-
           prepare_torrent_input(search_result.download_url, search_result.indexer) do
      # Extract detected type from the downloaded content
      detected_type =
        case torrent_input_result do
          {:file, _body, type} -> type
          _ -> nil
        end

      # Use detected type as fallback if download_type is nil
      final_download_type = download_type || detected_type

      Logger.info(
        "File type detection: original=#{inspect(download_type)}, detected=#{inspect(detected_type)}, final=#{inspect(final_download_type)}"
      )

      # Update opts with the final download type and title
      opts_with_type =
        opts
        |> Keyword.put(:download_type, final_download_type)
        |> Keyword.put(:title, search_result.title)

      # Now select the appropriate client based on the final type
      with {:ok, client_config} <- select_download_client(opts_with_type),
           {:ok, adapter} <- get_adapter_for_client(client_config) do
        # Extract the actual torrent input (without the type)
        torrent_input =
          case torrent_input_result do
            {:file, body, _type} -> {:file, body}
            other -> other
          end

        # Add to the selected client
        case add_torrent_to_client_with_input(
               adapter,
               client_config,
               torrent_input,
               opts_with_type
             ) do
          {:ok, client_id} ->
            {:ok, client_config, client_id, final_download_type}

          {:error, _} = error ->
            error
        end
      end
    end
  end

  # Version of add_torrent_to_client that accepts pre-downloaded input
  defp add_torrent_to_client_with_input(adapter, client_config, torrent_input, opts) do
    client_map_config = config_to_map(client_config)
    category = Keyword.get(opts, :category, client_config.category)
    title = Keyword.get(opts, :title)

    torrent_opts =
      []
      |> maybe_add_opt(:category, category)
      |> maybe_add_opt(:title, title)

    case Client.add_torrent(adapter, client_map_config, torrent_input, torrent_opts) do
      {:ok, client_id} ->
        {:ok, client_id}

      {:error, error} ->
        {:error, {:client_error, error}}
    end
  end

  defp apply_download_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:media_item_id, media_item_id}, query ->
        where(query, [d], d.media_item_id == ^media_item_id)

      {:episode_id, episode_id}, query ->
        where(query, [d], d.episode_id == ^episode_id)

      _other, query ->
        query
    end)
  end

  @doc """
  Broadcasts a download update to all subscribed LiveViews.
  """
  @spec broadcast_download_update(binary()) :: :ok | {:error, term()}
  def broadcast_download_update(download_id) do
    PubSub.broadcast(Mydia.PubSub, "downloads", {:download_updated, download_id})
  end

  ## Private Functions - Download Initiation

  defp check_for_duplicate_download(search_result, opts) do
    media_item_id = Keyword.get(opts, :media_item_id)
    episode_id = Keyword.get(opts, :episode_id)
    download_reason = Keyword.get(opts, :download_reason)
    # Legacy support: manual: true maps to download_reason: :manual
    manual? = Keyword.get(opts, :manual, false)
    skip_file_check? = manual? or download_reason in [:manual, :upgrade]

    # Always check for active downloads to prevent downloading the same thing twice
    with :ok <- check_for_active_download(search_result, media_item_id, episode_id) do
      # Skip media file check for manual downloads (user explicitly chose this release)
      # and upgrade downloads (a file exists by definition - we're replacing it)
      if skip_file_check? do
        :ok
      else
        check_for_existing_media_files(search_result, media_item_id, episode_id)
      end
    end
  end

  defp check_for_active_download(search_result, media_item_id, episode_id) do
    # Query for active downloads (not completed and not failed)
    base_query =
      Download
      |> where([d], is_nil(d.completed_at) and is_nil(d.error_message))

    # Add filters based on what we're downloading
    query =
      cond do
        # For episodes, check if there's an active download for this episode
        episode_id ->
          where(base_query, [d], d.episode_id == ^episode_id)

        # For season packs, check if there's an active download for same media_item and season
        media_item_id &&
            match?(
              %SearchResultMetadata{season_pack: true, season_number: _},
              search_result.metadata
            ) ->
          season_number = search_result.metadata.season_number

          base_query
          |> where([d], d.media_item_id == ^media_item_id)
          |> where([d], ^Mydia.DB.json_is_true(:metadata, "$.season_pack"))
          |> where(
            [d],
            ^Mydia.DB.json_integer_equals(:metadata, "$.season_number", season_number)
          )

        # For movies or other media, check if there's an active download for this media_item
        media_item_id ->
          where(base_query, [d], d.media_item_id == ^media_item_id)

        # No media association (e.g., music, books, adult libraries)
        # Check by download_url to prevent downloading the same file twice
        true ->
          where(base_query, [d], d.download_url == ^search_result.download_url)
      end

    active_downloads = Repo.all(query)

    if active_downloads == [] do
      :ok
    else
      # Verify each "active" download still exists in the download client
      case verify_downloads_in_client(active_downloads) do
        :all_stale ->
          # All were stale/orphaned - allow the new download
          :ok

        :has_active ->
          season_info =
            case search_result.metadata do
              %SearchResultMetadata{season_pack: true, season_number: sn} -> " (season #{sn})"
              _ -> ""
            end

          Logger.info("Skipping download - active download already exists#{season_info}",
            media_item_id: media_item_id,
            episode_id: episode_id
          )

          {:error, :duplicate_download}
      end
    end
  end

  defp verify_downloads_in_client(downloads) do
    has_active =
      Enum.any?(downloads, fn download ->
        case verify_single_download_in_client(download) do
          :active -> true
          :stale -> false
        end
      end)

    if has_active, do: :has_active, else: :all_stale
  end

  defp verify_single_download_in_client(download) do
    with {:ok, client_config} <- find_client_config(download.download_client),
         {:ok, adapter} <- get_adapter_for_client(client_config) do
      client_map_config = config_to_map(client_config)

      case Client.get_status(adapter, client_map_config, download.download_client_id) do
        {:ok, _status} ->
          :active

        {:error, %{type: :not_found}} ->
          Logger.warning("Active download not found in client, marking as failed",
            download_id: download.id,
            title: download.title,
            client: download.download_client
          )

          mark_download_failed(download, "Torrent no longer exists in download client")
          :stale

        {:error, reason} ->
          # Client error (connection issue, etc.) - assume download is still active
          # to avoid accidentally re-downloading
          Logger.warning("Could not verify download in client, assuming active",
            download_id: download.id,
            reason: inspect(reason)
          )

          :active
      end
    else
      {:error, _reason} ->
        # Client config not found - can't verify, assume active
        :active
    end
  end

  defp check_for_existing_media_files(search_result, media_item_id, episode_id) do
    alias Mydia.Media.MediaItem

    cond do
      # For episodes, check if media files already exist for this episode
      episode_id ->
        query = from(f in MediaFile, where: f.episode_id == ^episode_id and is_nil(f.trashed_at))

        if Repo.exists?(query) do
          Logger.info("Skipping download - media files already exist for episode",
            episode_id: episode_id
          )

          {:error, :duplicate_download}
        else
          :ok
        end

      # For season packs, check if any episodes in the season already have media files
      media_item_id &&
          match?(
            %SearchResultMetadata{season_pack: true, season_number: _},
            search_result.metadata
          ) ->
        season_number = search_result.metadata.season_number

        # Get all episodes for this season
        episodes_query =
          from(e in Episode,
            where: e.media_item_id == ^media_item_id and e.season_number == ^season_number,
            select: e.id
          )

        episode_ids = Repo.all(episodes_query)

        if episode_ids != [] do
          # Check if any of these episodes have media files
          media_files_query =
            from(f in MediaFile, where: f.episode_id in ^episode_ids and is_nil(f.trashed_at))

          if Repo.exists?(media_files_query) do
            Logger.info(
              "Skipping download - media files already exist for some episodes in season",
              media_item_id: media_item_id,
              season_number: season_number
            )

            {:error, :duplicate_download}
          else
            :ok
          end
        else
          # No episodes found for this season yet - allow download
          :ok
        end

      # For media items (movies or TV shows)
      media_item_id ->
        # Get the media item to check its type
        case Repo.get(MediaItem, media_item_id) do
          %MediaItem{type: "tv_show"} ->
            # TV shows can have multiple downloads for different seasons/episodes
            # Don't block based on existing media files - the user may be downloading
            # additional seasons or complete series packs
            Logger.debug(
              "Allowing download for TV show - TV shows can have multiple season downloads",
              media_item_id: media_item_id
            )

            :ok

          %MediaItem{type: "movie"} ->
            # For movies, check if non-trashed media files already exist
            query =
              from(f in MediaFile,
                where: f.media_item_id == ^media_item_id and is_nil(f.trashed_at)
              )

            if Repo.exists?(query) do
              Logger.info("Skipping download - media files already exist for movie",
                media_item_id: media_item_id
              )

              {:error, :duplicate_download}
            else
              :ok
            end

          nil ->
            # Media item not found, allow download (shouldn't happen normally)
            Logger.warning("Media item not found during duplicate check",
              media_item_id: media_item_id
            )

            :ok
        end

      # No media association, can't check for existing files
      true ->
        :ok
    end
  end

  defp select_download_client(opts) do
    client_name = Keyword.get(opts, :client_name)
    download_type = Keyword.get(opts, :download_type)

    cond do
      # Use specific client if requested
      client_name ->
        case find_client_by_name(client_name) do
          nil -> {:error, {:client_not_found, client_name}}
          client -> {:ok, client}
        end

      # Otherwise select by priority, filtered by download type
      true ->
        case select_client_by_priority(download_type) do
          nil -> {:error, :no_clients_configured}
          client -> {:ok, client}
        end
    end
  end

  defp find_client_by_name(name) do
    Settings.list_download_client_configs()
    |> Enum.find(&(&1.name == name && &1.enabled))
  end

  defp select_client_by_priority(download_type) do
    # Torrent clients
    torrent_clients = [:transmission, :qbittorrent, :rtorrent]
    # Usenet clients
    usenet_clients = [:nzbget, :sabnzbd]

    client =
      Settings.list_download_client_configs()
      |> Enum.filter(& &1.enabled)
      |> Enum.filter(fn client ->
        case download_type do
          :torrent -> client.type in torrent_clients
          :nzb -> client.type in usenet_clients
          # No filter if type unknown
          _ -> true
        end
      end)
      |> Enum.sort_by(& &1.priority, :asc)
      |> List.first()

    if client do
      Logger.info(
        "Selected download client: #{client.name} (type: #{client.type}, priority: #{client.priority}) for download_type: #{download_type}"
      )
    else
      Logger.warning("No suitable client found for download_type: #{download_type}")
    end

    client
  end

  defp get_adapter_for_client(client_config) do
    case Registry.get_adapter(client_config.type) do
      {:ok, adapter} ->
        Logger.info("Using adapter #{inspect(adapter)} for client type #{client_config.type}")
        {:ok, adapter}

      {:error, _} = error ->
        error
    end
  end

  defp create_download_record(search_result, client_config, client_id, opts) do
    # Build DownloadMetadata struct from search result
    metadata_attrs = %{
      size: search_result.size,
      seeders: search_result.seeders,
      leechers: search_result.leechers,
      quality: search_result.quality,
      download_protocol: search_result.download_protocol
    }

    # Add season pack metadata if present
    metadata_attrs =
      case search_result.metadata do
        %SearchResultMetadata{season_pack: true, season_number: season_number} ->
          Map.merge(metadata_attrs, %{
            season_pack: true,
            season_number: season_number
          })

        _ ->
          metadata_attrs
      end

    # Create DownloadMetadata struct and convert to map for database storage
    metadata = metadata_attrs |> DownloadMetadata.new() |> DownloadMetadata.to_map()

    # Store download_reason in metadata for post-import processing (e.g., upgrade cleanup)
    download_reason = Keyword.get(opts, :download_reason)

    metadata =
      if download_reason,
        do: Map.put(metadata, "download_reason", to_string(download_reason)),
        else: metadata

    attrs = %{
      indexer: search_result.indexer,
      title: search_result.title,
      download_url: search_result.download_url,
      download_client: client_config.name,
      download_client_id: client_id,
      media_item_id: Keyword.get(opts, :media_item_id),
      episode_id: Keyword.get(opts, :episode_id),
      library_path_id: Keyword.get(opts, :library_path_id),
      metadata: metadata
    }

    create_download(attrs)
  end

  defp create_download_record_with_retry(search_result, client_config, client_id, opts) do
    case create_download_record(search_result, client_config, client_id, opts) do
      {:ok, download} ->
        {:ok, download}

      {:error, %Ecto.Changeset{} = changeset}
      when is_struct(changeset, Ecto.Changeset) ->
        if has_unique_constraint_error?(changeset, :download_client) do
          Logger.warning(
            "Unique constraint on download_client_id, cleaning stale record and retrying",
            client: client_config.name,
            client_id: client_id
          )

          case find_stale_download(client_config.name, client_id) do
            nil ->
              {:error, changeset}

            stale_download ->
              Logger.info("Deleting stale download record",
                download_id: stale_download.id,
                title: stale_download.title
              )

              delete_download(stale_download)
              create_download_record(search_result, client_config, client_id, opts)
          end
        else
          {:error, changeset}
        end

      error ->
        error
    end
  end

  defp has_unique_constraint_error?(%Ecto.Changeset{} = changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp find_stale_download(client_name, client_id) do
    Download
    |> where([d], d.download_client == ^client_name and d.download_client_id == ^client_id)
    |> Repo.one()
  end

  ## Private Functions - Client Status Fetching

  defp get_configured_clients do
    Settings.list_download_client_configs()
    |> Enum.filter(& &1.enabled)
  end

  defp fetch_all_client_statuses(clients) do
    # Fetch torrents from all clients concurrently
    clients
    |> Task.async_stream(
      fn client_config ->
        adapter = get_adapter_module(client_config.type)
        config = config_to_map(client_config)

        case Client.list_torrents(adapter, config, []) do
          {:ok, torrents} ->
            {client_config.name, torrents}

          {:error, error} ->
            Logger.warning(
              "Failed to fetch torrents from #{client_config.name}: #{inspect(error)}"
            )

            {client_config.name, []}
        end
      end,
      timeout: :infinity,
      max_concurrency: 10
    )
    |> Enum.reduce(%{}, fn
      {:ok, {client_name, torrents}}, acc ->
        # Index torrents by client_id for fast lookup
        torrents_map =
          torrents
          |> Enum.map(fn torrent -> {torrent.id, torrent} end)
          |> Map.new()

        Map.put(acc, client_name, torrents_map)

      _, acc ->
        acc
    end)
  end

  defp enrich_download_with_status(download, client_statuses) do
    # Find the torrent status from the appropriate client
    torrent_status =
      client_statuses
      |> Map.get(download.download_client, %{})
      |> Map.get(download.download_client_id)

    if torrent_status do
      # Convert metadata map to struct for type-safe access
      metadata = DownloadMetadata.from_map(download.metadata)

      # Merge download DB record with real-time client status
      EnrichedDownload.new(%{
        id: download.id,
        media_item_id: download.media_item_id,
        episode_id: download.episode_id,
        media_item: download.media_item,
        episode: download.episode,
        title: download.title,
        indexer: download.indexer,
        download_url: download.download_url,
        download_client: download.download_client,
        download_client_id: download.download_client_id,
        metadata: download.metadata,
        match_status: download.match_status,
        inserted_at: download.inserted_at,
        # Real-time fields from client
        status: status_from_torrent_state(torrent_status.state),
        progress: torrent_status.progress,
        download_speed: torrent_status.download_speed,
        upload_speed: torrent_status.upload_speed,
        eta: torrent_status.eta,
        size: torrent_status.size,
        downloaded: torrent_status.downloaded,
        uploaded: torrent_status.uploaded,
        ratio: torrent_status.ratio,
        seeders: if(metadata, do: metadata.seeders, else: nil),
        leechers: if(metadata, do: metadata.leechers, else: nil),
        save_path: torrent_status.save_path,
        completed_at: download.completed_at || torrent_status.completed_at,
        error_message: download.error_message,
        # Preserve database completed_at for tracking if we've already processed it
        db_completed_at: download.completed_at,
        imported_at: download.imported_at,
        import_retry_count: download.import_retry_count,
        import_last_error: download.import_last_error,
        import_next_retry_at: download.import_next_retry_at,
        import_failed_at: download.import_failed_at
      })
    else
      # Download not found in client - might be removed or completed
      enrich_download_with_empty_status(download)
    end
  end

  defp enrich_download_with_empty_status(download) do
    # Download exists in DB but not in client
    # Could be completed and removed, or manually deleted from client
    status =
      cond do
        download.imported_at -> "imported"
        download.completed_at -> "completed"
        download.error_message -> "failed"
        true -> "missing"
      end

    # Convert metadata map to struct for type-safe access
    metadata = DownloadMetadata.from_map(download.metadata)

    EnrichedDownload.new(%{
      id: download.id,
      media_item_id: download.media_item_id,
      episode_id: download.episode_id,
      media_item: download.media_item,
      episode: download.episode,
      title: download.title,
      indexer: download.indexer,
      download_url: download.download_url,
      download_client: download.download_client,
      download_client_id: download.download_client_id,
      metadata: download.metadata,
      match_status: download.match_status,
      inserted_at: download.inserted_at,
      status: status,
      progress: if(download.completed_at, do: 100.0, else: 0.0),
      download_speed: 0,
      upload_speed: 0,
      eta: nil,
      size: if(metadata, do: metadata.size, else: 0),
      downloaded: 0,
      uploaded: 0,
      ratio: 0.0,
      seeders: nil,
      leechers: nil,
      save_path: nil,
      completed_at: download.completed_at,
      error_message: download.error_message,
      # Preserve database completed_at for tracking if we've already processed it
      db_completed_at: download.completed_at,
      imported_at: download.imported_at,
      import_retry_count: download.import_retry_count,
      import_last_error: download.import_last_error,
      import_next_retry_at: download.import_next_retry_at,
      import_failed_at: download.import_failed_at
    })
  end

  defp status_from_torrent_state(state) do
    case state do
      :downloading -> "downloading"
      :seeding -> "seeding"
      :completed -> "completed"
      :paused -> "paused"
      :checking -> "checking"
      :error -> "failed"
      _ -> "unknown"
    end
  end

  defp apply_status_filters(downloads, :all), do: downloads

  defp apply_status_filters(downloads, :active) do
    Enum.filter(downloads, fn d ->
      # Active downloads are those that haven't been imported yet
      # and are currently downloading, seeding, checking, or paused
      is_nil(d.imported_at) and d.status in ["downloading", "seeding", "checking", "paused"]
    end)
  end

  defp apply_status_filters(downloads, :completed) do
    Enum.filter(downloads, &(&1.status == "completed"))
  end

  # Filter for imported downloads (shown in Completed tab)
  # These are downloads that have been successfully imported to the library
  # but may still be seeding in the download client
  defp apply_status_filters(downloads, :imported) do
    Enum.filter(downloads, fn d ->
      not is_nil(d.imported_at)
    end)
  end

  defp apply_status_filters(downloads, :failed) do
    Enum.filter(downloads, fn d ->
      # Show downloads that failed in the client OR have import failures
      # Exclude unmatched and unresolved_files which have their own sections
      (d.status in ["failed", "missing"] || not is_nil(d.import_failed_at)) and
        d.match_status not in ["unmatched", "unresolved_files"]
    end)
  end

  defp apply_status_filters(downloads, :unmatched) do
    Enum.filter(downloads, fn d ->
      d.match_status == "unmatched"
    end)
  end

  defp apply_status_filters(downloads, :unresolved_files) do
    Enum.filter(downloads, fn d ->
      d.match_status == "unresolved_files"
    end)
  end

  defp find_client_config(client_name) do
    case find_client_by_name(client_name) do
      nil -> {:error, {:client_not_found, client_name}}
      client -> {:ok, client}
    end
  end

  defp get_adapter_module(:qbittorrent), do: Mydia.Downloads.Client.QBittorrent
  defp get_adapter_module(:transmission), do: Mydia.Downloads.Client.Transmission
  defp get_adapter_module(:rtorrent), do: Mydia.Downloads.Client.Rtorrent
  defp get_adapter_module(:blackhole), do: Mydia.Downloads.Client.Blackhole
  defp get_adapter_module(:http), do: Mydia.Downloads.Client.HTTP
  defp get_adapter_module(:sabnzbd), do: Mydia.Downloads.Client.Sabnzbd
  defp get_adapter_module(:nzbget), do: Mydia.Downloads.Client.Nzbget
  defp get_adapter_module(_), do: nil

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

  defp prepare_torrent_input(url, indexer_name) do
    cond do
      # Magnet links can be used directly
      String.starts_with?(url, "magnet:") ->
        {:ok, {:magnet, url}}

      # For HTTP(S) URLs, download the torrent file content
      # This avoids redirect issues that download clients can't handle
      String.starts_with?(url, "http://") or String.starts_with?(url, "https://") ->
        download_torrent_file(url, indexer_name)

      # Unknown format, try as URL
      true ->
        {:ok, {:url, url}}
    end
  end

  defp download_torrent_file(url, indexer_name) do
    Logger.info("Downloading file from URL: #{url}")

    # Get download config for the indexer (cookies and FlareSolverr setting)
    download_config = get_indexer_download_config(indexer_name)

    if download_config.flaresolverr_enabled do
      Logger.info("Using FlareSolverr for download from: #{indexer_name}")
      download_via_flaresolverr(url, download_config.cookies)
    else
      download_direct(url, download_config.cookie_header)
    end
  end

  # Encodes a URL to ensure special characters in the path are properly escaped.
  # This handles URLs with spaces, brackets, and other characters that would
  # otherwise cause Req to fail with :invalid_request_target.
  # Example: "http://host/path/Movie Title (2008).nzb" becomes
  #          "http://host/path/Movie%20Title%20%282008%29.nzb"
  defp encode_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: nil} = uri ->
        # No path to encode
        URI.to_string(uri)

      %URI{path: path} = uri ->
        # Encode only the path portion, preserving the rest
        # Split path into segments and encode each one
        encoded_path =
          path
          |> String.split("/")
          |> Enum.map(fn segment ->
            # URI.encode/2 encodes special characters but preserves already-encoded ones
            URI.encode(segment, &URI.char_unreserved?/1)
          end)
          |> Enum.join("/")

        URI.to_string(%{uri | path: encoded_path})
    end
  end

  # Download directly with cookies
  defp download_direct(url, cookie_header) do
    if cookie_header != "" do
      Logger.debug("Using auth cookies for download")
    end

    # Encode the URL to handle special characters (spaces, brackets, etc.)
    encoded_url = encode_url(url)

    # First check if the URL redirects to a magnet link
    # by manually following redirects (Req can't handle magnet: scheme)
    case follow_to_final_url(encoded_url, cookie_header) do
      {:ok, {:magnet, magnet_url}} ->
        Logger.debug("URL redirected to magnet link")
        {:ok, {:magnet, magnet_url}}

      {:ok, {:http, final_url}} ->
        # Download the actual torrent file with auth cookies
        req_opts = if cookie_header != "", do: [headers: [{"cookie", cookie_header}]], else: []

        case Req.get(final_url, req_opts) do
          {:ok, %{status: 200, body: body}} when is_binary(body) ->
            Logger.info("Successfully downloaded file (#{byte_size(body)} bytes)")

            Logger.info(
              "Content preview (first 500 chars): #{inspect(String.slice(body, 0, 500))}"
            )

            # Check if it looks like an NZB file
            is_nzb = String.contains?(body, "<?xml") and String.contains?(body, "nzb")

            is_torrent =
              String.starts_with?(body, "d8:announce") or
                (byte_size(body) > 11 and :binary.part(body, 0, 11) == "d8:announce")

            # Determine file type
            detected_type =
              cond do
                is_nzb -> :nzb
                is_torrent -> :torrent
                true -> nil
              end

            Logger.info(
              "File type detection: is_nzb=#{is_nzb}, is_torrent=#{is_torrent}, detected_type=#{inspect(detected_type)}"
            )

            # If we got HTML content (detected_type=nil), try to extract magnet link
            if detected_type == nil do
              case extract_magnet_from_html(body) do
                {:ok, magnet_url} ->
                  Logger.info("Extracted magnet link from HTML page")
                  {:ok, {:magnet, magnet_url}}

                {:error, :no_magnet_found} ->
                  Logger.error(
                    "Downloaded HTML content but no magnet link found. Page may require further navigation."
                  )

                  {:error,
                   {:download_failed,
                    "Downloaded page is HTML, not a torrent file. No magnet link found on page."}}
              end
            else
              {:ok, {:file, body, detected_type}}
            end

          {:ok, %{status: status, body: body}} ->
            # Log the response body for debugging - it often contains error details
            body_preview =
              if is_binary(body) and byte_size(body) > 0 do
                String.slice(to_string(body), 0, 1000)
              else
                "(empty body)"
              end

            Logger.error(
              "Failed to download torrent file: HTTP #{status}, response: #{body_preview}"
            )

            {:error, {:download_failed, "HTTP #{status}: #{body_preview}"}}

          {:error, exception} ->
            Logger.error("Failed to download torrent file: #{inspect(exception)}")
            {:error, {:download_failed, "Connection error: #{inspect(exception)}"}}
        end

      {:error, :too_many_redirects} ->
        Logger.error("Too many redirects when downloading from: #{url}")
        {:error, {:download_failed, "Too many redirects (maximum 10)"}}

      {:error, {:redirect_error, message}} ->
        Logger.error("Redirect error for #{url}: #{message}")
        {:error, {:download_failed, "Redirect error: #{message}"}}

      {:error, {:http_error, exception}} ->
        Logger.error("HTTP error when downloading from #{url}: #{inspect(exception)}")
        {:error, {:download_failed, "Connection failed: #{inspect(exception)}"}}

      {:error, {:unexpected_status, status}} ->
        Logger.error("Unexpected HTTP status #{status} when downloading from: #{url}")
        {:error, {:download_failed, "Unexpected HTTP status: #{status}"}}

      {:error, reason} ->
        Logger.error("Failed to download torrent file from #{url}: #{inspect(reason)}")
        {:error, {:download_failed, inspect(reason)}}
    end
  end

  # Download via FlareSolverr for Cloudflare-protected sites
  defp download_via_flaresolverr(url, cookies) do
    alias Mydia.Indexers.FlareSolverr

    if not FlareSolverr.enabled?() do
      Logger.error("FlareSolverr required but not enabled/configured")
      {:error, {:download_failed, "FlareSolverr required but not configured"}}
    else
      # Pass cookies to FlareSolverr request
      flaresolverr_opts =
        if cookies != [] do
          [cookies: cookies]
        else
          []
        end

      case FlareSolverr.get(url, flaresolverr_opts) do
        {:ok, response} ->
          body = response.solution.response

          if is_binary(body) and byte_size(body) > 0 do
            Logger.info("FlareSolverr downloaded file (#{byte_size(body)} bytes)")

            # Check if response is a magnet link redirect
            if String.starts_with?(body, "magnet:") do
              {:ok, {:magnet, String.trim(body)}}
            else
              # Detect file type
              is_nzb = String.contains?(body, "<?xml") and String.contains?(body, "nzb")

              is_torrent =
                String.starts_with?(body, "d8:announce") or
                  (byte_size(body) > 11 and :binary.part(body, 0, 11) == "d8:announce")

              detected_type =
                cond do
                  is_nzb -> :nzb
                  is_torrent -> :torrent
                  true -> nil
                end

              Logger.info(
                "FlareSolverr file type detection: detected_type=#{inspect(detected_type)}"
              )

              # If we got HTML content (detected_type=nil), try to extract magnet link
              if detected_type == nil do
                case extract_magnet_from_html(body) do
                  {:ok, magnet_url} ->
                    Logger.info("Extracted magnet link from HTML page")
                    {:ok, {:magnet, magnet_url}}

                  {:error, :no_magnet_found} ->
                    Logger.error(
                      "FlareSolverr returned HTML content but no magnet link found. Page may require further navigation."
                    )

                    {:error,
                     {:download_failed,
                      "Downloaded page is HTML, not a torrent file. No magnet link found on page."}}
                end
              else
                {:ok, {:file, body, detected_type}}
              end
            end
          else
            Logger.error("FlareSolverr returned empty response for: #{url}")
            {:error, {:download_failed, "Empty response from FlareSolverr"}}
          end

        {:error, reason} ->
          Logger.error("FlareSolverr download failed: #{inspect(reason)}")
          {:error, {:download_failed, "FlareSolverr error: #{inspect(reason)}"}}
      end
    end
  end

  defp follow_to_final_url(url, cookie_header, redirects_remaining \\ 10)
  defp follow_to_final_url(_url, _cookie_header, 0), do: {:error, :too_many_redirects}

  defp follow_to_final_url(url, cookie_header, redirects_remaining) do
    # Build request options with cookies if available
    req_opts =
      [redirect: false] ++
        if(cookie_header != "", do: [headers: [{"cookie", cookie_header}]], else: [])

    # Try HEAD request first - use redirect: false to get redirect responses directly
    # instead of following them, which avoids exception handling
    case Req.head(url, req_opts) do
      {:ok, %{status: status} = response} when status in 301..308 ->
        # This is a redirect response
        case get_location_header(response.headers) do
          nil ->
            Logger.error("Redirect (#{status}) missing Location header for URL: #{url}")
            {:error, {:redirect_error, "Redirect missing Location header"}}

          location ->
            if String.starts_with?(location, "magnet:") do
              {:ok, {:magnet, location}}
            else
              # Follow the redirect, encoding the location URL to handle special characters
              follow_to_final_url(encode_url(location), cookie_header, redirects_remaining - 1)
            end
        end

      {:ok, %{status: 200}} ->
        # No redirect, this is the final URL
        {:ok, {:http, url}}

      {:ok, %{status: 405}} ->
        # HEAD not allowed, try GET as fallback
        follow_to_final_url_with_get(url, cookie_header, redirects_remaining)

      {:ok, %{status: status, body: body}} ->
        body_preview =
          if is_binary(body) and byte_size(body) > 0 do
            String.slice(to_string(body), 0, 500)
          else
            "(empty body)"
          end

        Logger.error(
          "Unexpected HTTP status #{status} during redirect check for URL: #{url}, response: #{body_preview}"
        )

        {:error, {:unexpected_status, status}}

      {:ok, %{status: status}} ->
        Logger.error("Unexpected HTTP status #{status} during redirect check for URL: #{url}")
        {:error, {:unexpected_status, status}}

      {:error, exception} ->
        {:error, {:http_error, exception}}
    end
  end

  defp follow_to_final_url_with_get(url, cookie_header, redirects_remaining) do
    # Fallback to GET when HEAD is not allowed
    # Build request options with cookies if available
    req_opts =
      [redirect: false] ++
        if(cookie_header != "", do: [headers: [{"cookie", cookie_header}]], else: [])

    case Req.get(url, req_opts) do
      {:ok, %{status: status} = response} when status in 301..308 ->
        # This is a redirect response
        case get_location_header(response.headers) do
          nil ->
            Logger.error("Redirect (#{status}) missing Location header for URL: #{url}")
            {:error, {:redirect_error, "Redirect missing Location header"}}

          location ->
            if String.starts_with?(location, "magnet:") do
              {:ok, {:magnet, location}}
            else
              # Follow the redirect, encoding the location URL to handle special characters
              follow_to_final_url(encode_url(location), cookie_header, redirects_remaining - 1)
            end
        end

      {:ok, %{status: 200}} ->
        # No redirect, this is the final URL
        {:ok, {:http, url}}

      {:ok, %{status: status, body: body}} ->
        body_preview =
          if is_binary(body) and byte_size(body) > 0 do
            String.slice(to_string(body), 0, 500)
          else
            "(empty body)"
          end

        Logger.error(
          "Unexpected HTTP status #{status} during GET redirect check for URL: #{url}, response: #{body_preview}"
        )

        {:error, {:unexpected_status, status}}

      {:ok, %{status: status}} ->
        Logger.error("Unexpected HTTP status #{status} during GET redirect check for URL: #{url}")

        {:error, {:unexpected_status, status}}

      {:error, exception} ->
        {:error, {:http_error, exception}}
    end
  end

  defp get_location_header(headers) do
    Enum.find_value(headers, fn
      {key, [value | _]} when key in ["location", "Location"] -> value
      {key, value} when key in ["location", "Location"] and is_binary(value) -> value
      _ -> nil
    end)
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Get download configuration for an indexer by name
  # Returns a map with cookies (formatted as header string) and flaresolverr_enabled flag
  defp get_indexer_download_config(nil) do
    %{cookie_header: "", cookies: [], flaresolverr_enabled: false}
  end

  defp get_indexer_download_config(indexer_name) when is_binary(indexer_name) do
    case Mydia.Indexers.get_cardigann_download_config(indexer_name) do
      nil ->
        %{cookie_header: "", cookies: [], flaresolverr_enabled: false}

      config ->
        %{
          cookie_header: format_cookies_for_header(config.cookies),
          cookies: config.cookies,
          flaresolverr_enabled: config.flaresolverr_enabled
        }
    end
  end

  # Convert cookie list to header string
  # Handles both map format (from FlareSolverr) and string format
  defp format_cookies_for_header([]), do: ""

  defp format_cookies_for_header(cookies) when is_list(cookies) do
    cookies
    |> Enum.map(&format_single_cookie/1)
    |> Enum.filter(&(&1 != nil))
    |> Enum.join("; ")
  end

  defp format_single_cookie(%{"name" => name, "value" => value}) when is_binary(name) do
    "#{name}=#{value}"
  end

  defp format_single_cookie(%{name: name, value: value}) when is_binary(name) do
    "#{name}=#{value}"
  end

  defp format_single_cookie(cookie) when is_binary(cookie) do
    # Already a string like "name=value" or "name=value; path=/"
    # Extract just the name=value part
    cookie |> String.split(";") |> List.first() |> String.trim()
  end

  defp format_single_cookie(_), do: nil

  # Extracts a magnet link from HTML content
  # This is used when FlareSolverr returns an HTML page (e.g., 1337x torrent detail page)
  # instead of a torrent file
  defp extract_magnet_from_html(html) when is_binary(html) do
    # Parse HTML and look for magnet links
    case Floki.parse_document(html) do
      {:ok, document} ->
        # Try multiple strategies to find magnet links

        # Strategy 1: Look for anchor tags with href starting with "magnet:"
        magnet_links =
          document
          |> Floki.find("a[href^='magnet:']")
          |> Floki.attribute("href")

        # Strategy 2: Also check for data attributes or onclick handlers that might contain magnet
        magnet_from_data =
          if magnet_links == [] do
            document
            |> Floki.find("[data-href^='magnet:'], [data-url^='magnet:']")
            |> Floki.attribute("data-href")
            |> Kernel.++(
              document
              |> Floki.find("[data-href^='magnet:'], [data-url^='magnet:']")
              |> Floki.attribute("data-url")
            )
          else
            []
          end

        all_magnets = magnet_links ++ magnet_from_data

        # Strategy 3: Regex fallback - look for magnet links in raw HTML
        all_magnets =
          if all_magnets == [] do
            case Regex.scan(~r/magnet:\?xt=urn:[a-zA-Z0-9]+:[a-zA-Z0-9]+[^"'\s<>]*/, html) do
              [] -> []
              matches -> Enum.map(matches, fn [match] -> match end)
            end
          else
            all_magnets
          end

        case all_magnets do
          [magnet | _] ->
            # Clean up the magnet link (decode HTML entities)
            cleaned_magnet =
              magnet
              |> String.replace("&amp;", "&")
              |> String.trim()

            {:ok, cleaned_magnet}

          [] ->
            {:error, :no_magnet_found}
        end

      {:error, _reason} ->
        # Try regex fallback if Floki can't parse the HTML
        case Regex.run(~r/magnet:\?xt=urn:[a-zA-Z0-9]+:[a-zA-Z0-9]+[^"'\s<>]*/, html) do
          [magnet | _] ->
            cleaned_magnet =
              magnet
              |> String.replace("&amp;", "&")
              |> String.trim()

            {:ok, cleaned_magnet}

          nil ->
            {:error, :no_magnet_found}
        end
    end
  end

  defp extract_magnet_from_html(_), do: {:error, :no_magnet_found}

  ## Transcode Job Management

  alias Mydia.Downloads.TranscodeJob

  @doc """
  Gets or creates a transcode job for a media file and resolution.

  If a job already exists, returns it. Otherwise creates a new job with "pending" status.

  ## Examples

      iex> get_or_create_job(media_file_id, "1080p")
      {:ok, %TranscodeJob{status: "pending"}}
  """
  @spec get_or_create_job(binary(), String.t()) ::
          {:ok, TranscodeJob.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_job(media_file_id, resolution) do
    # Explicitly filter for download type jobs
    case Repo.get_by(TranscodeJob,
           media_file_id: media_file_id,
           resolution: resolution,
           type: "download"
         ) do
      nil ->
        %TranscodeJob{}
        |> TranscodeJob.changeset(%{
          media_file_id: media_file_id,
          resolution: resolution,
          type: "download",
          status: "pending",
          progress: 0.0
        })
        |> Repo.insert()

      job ->
        {:ok, job}
    end
  end

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
  def get_cached_transcode(media_file_id, resolution) do
    TranscodeJob
    |> where([j], j.media_file_id == ^media_file_id)
    |> where([j], j.resolution == ^resolution)
    |> where([j], j.type == "download")
    |> where([j], j.status == "ready")
    |> Repo.one()
  end

  @doc """
  Updates the progress of a transcode job.

  Also sets the status to "transcoding" and records the start time if not already set.

  ## Examples

      iex> update_job_progress(job, 0.5)
      {:ok, %TranscodeJob{progress: 0.5, status: "transcoding"}}
  """
  @spec update_job_progress(TranscodeJob.t(), float()) ::
          {:ok, TranscodeJob.t()} | {:error, Ecto.Changeset.t()}
  def update_job_progress(%TranscodeJob{} = job, progress) do
    attrs = %{
      progress: progress,
      status: "transcoding"
    }

    attrs =
      if is_nil(job.started_at) do
        Map.put(attrs, :started_at, DateTime.utc_now())
      else
        attrs
      end

    case job
         |> TranscodeJob.changeset(attrs)
         |> Repo.update() do
      {:ok, updated_job} ->
        broadcast_job_update(updated_job.id)
        {:ok, updated_job}

      error ->
        error
    end
  end

  @doc """
  Marks a transcode job as complete.

  Sets status to "ready", records completion time, and stores output path and file size.

  ## Examples

      iex> complete_job(job, "/path/to/output.mp4", 1024000)
      {:ok, %TranscodeJob{status: "ready", completed_at: ~U[...]}}
  """
  @spec complete_job(TranscodeJob.t(), String.t(), non_neg_integer()) ::
          {:ok, TranscodeJob.t()} | {:error, Ecto.Changeset.t()}
  def complete_job(%TranscodeJob{} = job, output_path, file_size) do
    case job
         |> TranscodeJob.changeset(%{
           status: "ready",
           progress: 1.0,
           output_path: output_path,
           file_size: file_size,
           completed_at: DateTime.utc_now(),
           last_accessed_at: DateTime.utc_now()
         })
         |> Repo.update() do
      {:ok, updated_job} ->
        broadcast_job_update(updated_job.id)
        {:ok, updated_job}

      error ->
        error
    end
  end

  @doc """
  Marks a transcode job as failed.

  Sets status to "failed" and records the error message.

  ## Examples

      iex> fail_job(job, "FFmpeg error: invalid codec")
      {:ok, %TranscodeJob{status: "failed", error: "FFmpeg error: invalid codec"}}
  """
  @spec fail_job(TranscodeJob.t(), String.t()) ::
          {:ok, TranscodeJob.t()} | {:error, Ecto.Changeset.t()}
  def fail_job(%TranscodeJob{} = job, error_message) do
    case job
         |> TranscodeJob.changeset(%{
           status: "failed",
           error: error_message
         })
         |> Repo.update() do
      {:ok, updated_job} ->
        broadcast_job_update(updated_job.id)
        {:ok, updated_job}

      error ->
        error
    end
  end

  @doc """
  Updates the last_accessed_at timestamp for a transcode job.

  Used to track usage for cache eviction purposes.

  ## Examples

      iex> touch_last_accessed(job)
      {:ok, %TranscodeJob{last_accessed_at: ~U[...]}}
  """
  @spec touch_last_accessed(TranscodeJob.t()) ::
          {:ok, TranscodeJob.t()} | {:error, Ecto.Changeset.t()}
  def touch_last_accessed(%TranscodeJob{} = job) do
    job
    |> TranscodeJob.changeset(%{last_accessed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc """
  Broadcasts a transcode job update to all subscribed LiveViews.
  """
  @spec broadcast_job_update(binary()) :: :ok | {:error, term()}
  def broadcast_job_update(job_id) do
    PubSub.broadcast(Mydia.PubSub, "transcodes", {:job_updated, job_id})
  end

  @doc """
  Lists transcode jobs for a specific media file.

  Returns all download-type transcode jobs regardless of status.
  """
  @spec list_transcode_jobs_for_media_file(binary()) :: [TranscodeJob.t()]
  def list_transcode_jobs_for_media_file(media_file_id) do
    TranscodeJob
    |> where([j], j.media_file_id == ^media_file_id)
    |> where([j], j.type == "download")
    |> order_by([j], desc: j.updated_at)
    |> Repo.all()
  end

  @doc """
  Lists transcode jobs.

  ## Options
    - `:preload` - List of associations to preload
    - `:status` - List of status strings to filter by (e.g. ["pending", "transcoding"])
    - `:limit` - Maximum number of results to return
  """
  @spec list_transcode_jobs(keyword()) :: [TranscodeJob.t()]
  def list_transcode_jobs(opts \\ []) do
    TranscodeJob
    |> maybe_filter_status(opts[:status])
    |> maybe_preload(opts[:preload])
    |> order_by([j], desc: j.updated_at)
    |> maybe_limit(opts[:limit])
    |> Repo.all()
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, statuses) when is_list(statuses),
    do: where(query, [j], j.status in ^statuses)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  @doc """
  Cancels a transcode job.
  """
  @spec cancel_transcode_job(TranscodeJob.t()) :: {:ok, TranscodeJob.t()}
  def cancel_transcode_job(%TranscodeJob{} = job) do
    alias Mydia.Downloads.JobManager
    alias Mydia.Streaming.HlsSessionSupervisor

    case job.type do
      "download" ->
        # Convert schema string resolution to atom for JobManager
        resolution_atom =
          case job.resolution do
            "original" -> :original
            "1080p" -> :p1080
            "720p" -> :p720
            "480p" -> :p480
            _ -> :p720
          end

        # Cancel in JobManager
        JobManager.cancel_job(job.media_file_id, resolution_atom)

      "stream" ->
        # Stop HLS session if running
        if job.user_id do
          HlsSessionSupervisor.stop_session(job.media_file_id, job.user_id)
        end

      "direct" ->
        # Stop Direct Play session if running
        if job.user_id do
          HlsSessionSupervisor.stop_direct_session(job.media_file_id, job.user_id)
        end

      _ ->
        :ok
    end

    # Delete from DB
    Repo.delete(job)

    # Clean up output file if it exists (only for downloads)
    if job.output_path && File.exists?(job.output_path) do
      File.rm(job.output_path)
    end

    broadcast_job_update(job.id)
    {:ok, job}
  end

  @doc """
  Deletes all completed (ready) and failed transcode jobs and their files.
  """
  @spec delete_all_completed_jobs() :: :ok
  def delete_all_completed_jobs do
    jobs =
      TranscodeJob
      |> where([j], j.status in ["ready", "failed"])
      |> Repo.all()

    Enum.each(jobs, &cancel_transcode_job/1)
  end

  @doc """
  Deletes all streaming jobs.
  Should be called on startup to clean up zombie records.
  """
  @spec delete_all_streaming_jobs() :: {non_neg_integer(), nil | [term()]}
  def delete_all_streaming_jobs do
    Repo.delete_all(from j in TranscodeJob, where: j.type in ["stream", "direct"])
  end

  # --- Issues Tab Functions ---

  @doc """
  Manually matches an unmatched download to a media item, then triggers import.

  Sets the media_item_id (and optionally episode_id), clears match_status,
  and enqueues a MediaImport job.
  """
  def manually_match_download(%Download{} = download, media_item_id, episode_id \\ nil) do
    save_path = get_in(download.metadata || %{}, ["save_path"])

    # Keep match_status until import succeeds (import job clears it)
    attrs = %{
      media_item_id: media_item_id,
      episode_id: episode_id
    }

    case update_download(download, attrs) do
      {:ok, updated} ->
        %{
          "download_id" => updated.id,
          "save_path" => save_path,
          "cleanup_client" => true,
          "use_hardlinks" => true,
          "move_files" => false
        }
        |> Mydia.Jobs.MediaImport.new()
        |> Oban.insert()

        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  Refreshes match suggestions for an unmatched download by re-running TorrentMatcher.
  """
  def refresh_match_suggestions(%Download{} = download) do
    alias Mydia.Downloads.{TorrentParser, TorrentMatcher}

    suggestions =
      case TorrentParser.parse(download.title) do
        {:ok, parsed_info} ->
          try do
            TorrentMatcher.find_top_candidates(parsed_info,
              max_results: 3,
              monitored_only: false
            )
          rescue
            e ->
              Logger.warning("Failed to find match candidates: #{inspect(e)}",
                download_id: download.id
              )

              []
          end

        _ ->
          []
      end

    current_metadata = download.metadata || %{}
    updated_metadata = Map.put(current_metadata, "match_suggestions", suggestions)

    update_download(download, %{metadata: updated_metadata})
  end

  @doc """
  Resolves file-to-episode mappings for an unresolved download and triggers re-import.

  Accepts a list of `%{path: string, episode_id: binary_id}` mappings.
  """
  def resolve_file_mappings(%Download{} = download, mappings) when is_list(mappings) do
    # Build target_files for the MediaImport job (mappings always use string keys)
    target_files =
      Enum.map(mappings, fn mapping ->
        %{
          "path" => mapping["path"],
          "episode_id" => mapping["episode_id"]
        }
      end)

    # Don't clear match_status or unresolved_files metadata here — the import job
    # clears them on success. This preserves data for retry if import fails.
    case %{
           "download_id" => download.id,
           "target_files" => target_files,
           "use_hardlinks" => true,
           "move_files" => false
         }
         |> Mydia.Jobs.MediaImport.new()
         |> Oban.insert() do
      {:ok, _job} -> {:ok, download}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Dismisses (deletes) a download from the Issues tab.
  """
  def dismiss_download(%Download{} = download) do
    delete_download(download)
  end

  @doc """
  Bulk-dismisses failed/errored downloads that don't have special match_status.
  Only deletes downloads that have actually failed (error_message or import_failed_at set).
  """
  def dismiss_all_cancelled do
    from(d in Download,
      where:
        is_nil(d.match_status) and is_nil(d.imported_at) and
          (not is_nil(d.error_message) or not is_nil(d.import_failed_at))
    )
    |> Repo.delete_all()
  end
end
