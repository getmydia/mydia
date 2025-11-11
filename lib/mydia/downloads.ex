defmodule Mydia.Downloads do
  @moduledoc """
  The Downloads context handles download queue management.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Indexers.SearchResult
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
  def register_clients do
    Logger.info("Registering download client adapters...")

    # Register available client adapters
    Registry.register(:qbittorrent, Mydia.Downloads.Client.QBittorrent)
    Registry.register(:transmission, Mydia.Downloads.Client.Transmission)
    Registry.register(:sabnzbd, Mydia.Downloads.Client.Sabnzbd)
    Registry.register(:nzbget, Mydia.Downloads.Client.Nzbget)
    Registry.register(:http, Mydia.Downloads.Client.HTTP)

    Logger.info("Download client adapter registration complete")
    :ok
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
  def get_download!(id, opts \\ []) do
    Download
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Creates a download.
  """
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
  def mark_download_completed(%Download{} = download) do
    download
    |> Download.changeset(%{completed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc """
  Records an error message for a download.
  """
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
  Deletes a download.
  """
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
  def change_download(%Download{} = download, attrs \\ %{}) do
    Download.changeset(download, attrs)
  end

  @doc """
  Gets all active downloads from clients (downloads currently in progress).

  This is now a convenience wrapper around list_downloads_with_status
  with filter: :active.
  """
  def list_active_downloads(opts \\ []) do
    list_downloads_with_status(Keyword.put(opts, :filter, :active))
  end

  @doc """
  Counts active downloads (downloading, seeding, checking, paused).

  Returns the number of downloads currently in progress across all clients.
  """
  def count_active_downloads do
    list_active_downloads()
    |> length()
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
  def initiate_download(%SearchResult{} = search_result, opts \\ []) do
    # Use protocol from search result
    download_type = search_result.download_protocol
    Logger.info("Download protocol: #{inspect(download_type)} for #{search_result.title}")
    Logger.info("Full search_result struct: #{inspect(search_result, limit: :infinity)}")

    opts = Keyword.put(opts, :download_type, download_type)

    with :ok <- check_for_duplicate_download(search_result, opts),
         {:ok, client_config, client_id, detected_type} <-
           select_and_add_to_client(search_result, opts),
         {:ok, download} <- create_download_record(search_result, client_config, client_id, opts) do
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
    with {:ok, torrent_input_result} <- prepare_torrent_input(search_result.download_url) do
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

  # Check if a client type matches a download type
  defp client_type_matches?(client_type, download_type) do
    torrent_clients = [:transmission, :qbittorrent]
    usenet_clients = [:nzbget, :sabnzbd]

    case download_type do
      :torrent -> client_type in torrent_clients
      :nzb -> client_type in usenet_clients
      _ -> true
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

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, []), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)

  @doc """
  Broadcasts a download update to all subscribed LiveViews.
  """
  def broadcast_download_update(download_id) do
    PubSub.broadcast(Mydia.PubSub, "downloads", {:download_updated, download_id})
  end

  ## Private Functions - Download Initiation

  defp check_for_duplicate_download(search_result, opts) do
    media_item_id = Keyword.get(opts, :media_item_id)
    episode_id = Keyword.get(opts, :episode_id)

    # First check for active downloads (not completed and not failed)
    with :ok <- check_for_active_download(search_result, media_item_id, episode_id),
         :ok <- check_for_existing_media_files(search_result, media_item_id, episode_id) do
      :ok
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
        media_item_id && match?(%{season_pack: true, season_number: _}, search_result.metadata) ->
          season_number = search_result.metadata.season_number

          base_query
          |> where([d], d.media_item_id == ^media_item_id)
          |> where(
            [d],
            # Handle both boolean true (1) and string "true" for season_pack
            # SQLite json_extract returns 1 for JSON boolean true
            (fragment("json_extract(?, '$.season_pack')  = 1", d.metadata) or
               fragment("json_extract(?, '$.season_pack') = 'true'", d.metadata)) and
              fragment(
                "CAST(json_extract(?, '$.season_number') AS INTEGER) = ?",
                d.metadata,
                ^season_number
              )
          )

        # For movies or other media, check if there's an active download for this media_item
        media_item_id ->
          where(base_query, [d], d.media_item_id == ^media_item_id)

        # No media association, can't check for duplicates
        true ->
          base_query
      end

    case Repo.exists?(query) do
      true ->
        season_info =
          case search_result.metadata do
            %{season_pack: true, season_number: sn} -> " (season #{sn})"
            _ -> ""
          end

        Logger.info("Skipping download - active download already exists#{season_info}",
          media_item_id: media_item_id,
          episode_id: episode_id
        )

        {:error, :duplicate_download}

      false ->
        :ok
    end
  end

  defp check_for_existing_media_files(search_result, media_item_id, episode_id) do
    cond do
      # For episodes, check if media files already exist for this episode
      episode_id ->
        query = from(f in MediaFile, where: f.episode_id == ^episode_id)

        if Repo.exists?(query) do
          Logger.info("Skipping download - media files already exist for episode",
            episode_id: episode_id
          )

          {:error, :duplicate_download}
        else
          :ok
        end

      # For season packs, check if any episodes in the season already have media files
      media_item_id && match?(%{season_pack: true, season_number: _}, search_result.metadata) ->
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
            from(f in MediaFile, where: f.episode_id in ^episode_ids)

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

      # For movies, check if media files already exist for this media_item
      media_item_id ->
        query = from(f in MediaFile, where: f.media_item_id == ^media_item_id)

        if Repo.exists?(query) do
          Logger.info("Skipping download - media files already exist for media item",
            media_item_id: media_item_id
          )

          {:error, :duplicate_download}
        else
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

  defp select_client_by_priority(download_type \\ nil) do
    # Torrent clients
    torrent_clients = [:transmission, :qbittorrent]
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

  defp add_torrent_to_client(adapter, client_config, search_result, opts) do
    client_map_config = config_to_map(client_config)

    # For HTTP(S) URLs, download the torrent file and pass it as content
    # This avoids redirect issues that download clients can't handle
    with {:ok, torrent_input_result} <- prepare_torrent_input(search_result.download_url) do
      # Extract torrent input and detected type
      {torrent_input, detected_type} =
        case torrent_input_result do
          {:file, body, type} -> {{:file, body}, type}
          other -> {other, nil}
        end

      category = Keyword.get(opts, :category, client_config.category)

      torrent_opts =
        []
        |> maybe_add_opt(:category, category)

      case Client.add_torrent(adapter, client_map_config, torrent_input, torrent_opts) do
        {:ok, client_id} ->
          {:ok, client_id, detected_type}

        {:error, error} ->
          {:error, {:client_error, error}}
      end
    end
  end

  defp create_download_record(search_result, client_config, client_id, opts) do
    # Base metadata from search result
    base_metadata = %{
      size: search_result.size,
      seeders: search_result.seeders,
      leechers: search_result.leechers,
      quality: search_result.quality
    }

    # Merge with season pack metadata if present
    metadata =
      case search_result.metadata do
        %{season_pack: true} = season_metadata ->
          Map.merge(base_metadata, season_metadata)

        _ ->
          base_metadata
      end

    attrs = %{
      indexer: search_result.indexer,
      title: search_result.title,
      download_url: search_result.download_url,
      download_client: client_config.name,
      download_client_id: client_id,
      media_item_id: Keyword.get(opts, :media_item_id),
      episode_id: Keyword.get(opts, :episode_id),
      metadata: metadata
    }

    create_download(attrs)
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
      # Merge download DB record with real-time client status
      %{
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
        seeders: torrent_status[:seeders],
        leechers: torrent_status[:leechers],
        save_path: torrent_status.save_path,
        completed_at: download.completed_at || torrent_status.completed_at,
        error_message: download.error_message,
        # Preserve database completed_at for tracking if we've already processed it
        db_completed_at: download.completed_at
      }
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
        download.completed_at -> "completed"
        download.error_message -> "failed"
        true -> "missing"
      end

    %{
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
      inserted_at: download.inserted_at,
      status: status,
      progress: if(download.completed_at, do: 100.0, else: 0.0),
      download_speed: 0,
      upload_speed: 0,
      eta: nil,
      size: download.metadata["size"],
      downloaded: 0,
      uploaded: 0,
      ratio: 0.0,
      seeders: nil,
      leechers: nil,
      save_path: nil,
      completed_at: download.completed_at,
      error_message: download.error_message,
      # Preserve database completed_at for tracking if we've already processed it
      db_completed_at: download.completed_at
    }
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
      d.status in ["downloading", "seeding", "checking", "paused"]
    end)
  end

  defp apply_status_filters(downloads, :completed) do
    Enum.filter(downloads, &(&1.status == "completed"))
  end

  defp apply_status_filters(downloads, :failed) do
    Enum.filter(downloads, &(&1.status in ["failed", "missing"]))
  end

  defp find_client_config(client_name) do
    case find_client_by_name(client_name) do
      nil -> {:error, {:client_not_found, client_name}}
      client -> {:ok, client}
    end
  end

  defp get_adapter_module(:qbittorrent), do: Mydia.Downloads.Client.Qbittorrent
  defp get_adapter_module(:transmission), do: Mydia.Downloads.Client.Transmission
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
      options: config.connection_settings || %{}
    }
  end

  defp prepare_torrent_input(url) do
    cond do
      # Magnet links can be used directly
      String.starts_with?(url, "magnet:") ->
        {:ok, {:magnet, url}}

      # For HTTP(S) URLs, download the torrent file content
      # This avoids redirect issues that download clients can't handle
      String.starts_with?(url, "http://") or String.starts_with?(url, "https://") ->
        download_torrent_file(url)

      # Unknown format, try as URL
      true ->
        {:ok, {:url, url}}
    end
  end

  defp download_torrent_file(url) do
    Logger.info("Downloading file from URL: #{url}")

    # First check if the URL redirects to a magnet link
    # by manually following redirects (Req can't handle magnet: scheme)
    case follow_to_final_url(url) do
      {:ok, {:magnet, magnet_url}} ->
        Logger.debug("URL redirected to magnet link")
        {:ok, {:magnet, magnet_url}}

      {:ok, {:http, final_url}} ->
        # Download the actual torrent file
        case Req.get(final_url) do
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

            {:ok, {:file, body, detected_type}}

          {:ok, %{status: status}} ->
            Logger.error("Failed to download torrent file: HTTP #{status}")
            {:error, {:download_failed, "HTTP #{status}"}}

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

  defp follow_to_final_url(url, redirects_remaining \\ 10)
  defp follow_to_final_url(_url, 0), do: {:error, :too_many_redirects}

  defp follow_to_final_url(url, redirects_remaining) do
    # Try HEAD request first - use redirect: false to get redirect responses directly
    # instead of following them, which avoids exception handling
    case Req.head(url, redirect: false) do
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
              # Follow the redirect
              follow_to_final_url(location, redirects_remaining - 1)
            end
        end

      {:ok, %{status: 200}} ->
        # No redirect, this is the final URL
        {:ok, {:http, url}}

      {:ok, %{status: 405}} ->
        # HEAD not allowed, try GET as fallback
        follow_to_final_url_with_get(url, redirects_remaining)

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, exception} ->
        {:error, {:http_error, exception}}
    end
  end

  defp follow_to_final_url_with_get(url, redirects_remaining) do
    # Fallback to GET when HEAD is not allowed
    # Use redirect: false to get redirect responses directly
    case Req.get(url, redirect: false) do
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
              # Follow the redirect
              follow_to_final_url(location, redirects_remaining - 1)
            end
        end

      {:ok, %{status: 200}} ->
        # No redirect, this is the final URL
        {:ok, {:http, url}}

      {:ok, %{status: status}} ->
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
end
