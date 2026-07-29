defmodule Mydia.Downloads.History do
  @moduledoc false

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers

  use Mydia.QueryHelpers.Filterable,
    function_name: :apply_download_filters,
    filters: [
      media_item_id: :eq,
      episode_id: :eq
    ]

  alias Mydia.Repo
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.Structs.DownloadMetadata
  alias Mydia.Downloads.Structs.EnrichedDownload
  alias Mydia.Settings
  alias Phoenix.PubSub
  require Logger

  ## Public Functions

  def list_downloads(opts \\ []) do
    Download
    |> apply_download_filters(opts)
    |> maybe_preload(opts[:preload])
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

  @doc """
  Counts imported downloads — the set `clear_all_completed/1` would remove.

  Used to show a scope-accurate blast radius before the user confirms a
  destructive "delete files from disk" clear.
  """
  def count_completed do
    Download
    |> where([d], not is_nil(d.imported_at))
    |> Repo.aggregate(:count)
  end

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
      client_statuses = fetch_all_client_statuses(clients, downloads)

      # Enrich downloads with client status
      downloads
      |> Enum.map(&enrich_download_with_status(&1, client_statuses))
      |> apply_status_filters(opts[:filter] || :all)
    end
  end

  def get_download!(id, opts \\ []) do
    Download
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

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
  Lists failed downloads classified as a path-mapping mismatch whose reported
  path is at or under `remote_prefix`. Used to fan out an applied mapping to
  every affected download.
  """
  def list_path_mapping_mismatches_under_prefix(remote_prefix) when is_binary(remote_prefix) do
    like_pattern = remote_prefix <> "/%"

    Download
    |> where([d], not is_nil(d.import_failed_at))
    |> where([d], d.import_failure_reason == "path_mapping_mismatch")
    |> where(
      [d],
      d.import_reported_path == ^remote_prefix or like(d.import_reported_path, ^like_pattern)
    )
    |> Repo.all()
  end

  @doc """
  Lists the distinct reported paths of downloads that failed import because of
  a path-mapping mismatch. These are the remote paths Mydia saw but could not
  translate, making them the most useful suggestions for a `remote_prefix`.
  """
  def list_failed_remote_paths do
    Download
    |> where([d], not is_nil(d.import_failed_at))
    |> where([d], d.import_failure_reason == "path_mapping_mismatch")
    |> where([d], not is_nil(d.import_reported_path))
    |> select([d], d.import_reported_path)
    |> distinct(true)
    |> Repo.all()
  end

  def mark_download_completed(%Download{} = download) do
    download
    |> Download.changeset(%{completed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def mark_download_failed(%Download{} = download, error_message) do
    download
    |> Download.changeset(%{error_message: error_message})
    |> Repo.update()
  end

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

  def change_download(%Download{} = download, attrs \\ %{}) do
    Download.changeset(download, attrs)
  end

  def list_active_downloads(opts \\ []) do
    list_downloads_with_status(Keyword.put(opts, :filter, :active))
  end

  def count_active_downloads do
    list_active_downloads()
    |> length()
  end

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

  def broadcast_download_update(download_id) do
    PubSub.broadcast(Mydia.PubSub, "downloads", {:download_updated, download_id})
  end

  ## Private Functions - Client Status Fetching

  defp get_configured_clients do
    Settings.list_download_client_configs()
    |> Enum.filter(& &1.enabled)
  end

  defp fetch_all_client_statuses(clients, downloads) do
    # Fetch torrents from all clients concurrently. We deliberately distinguish
    # between two outcomes that previously collapsed into "empty list":
    #
    #   - {:reachable, torrents_map} — the client answered, here are its torrents
    #   - :unreachable                — the client errored; we don't know its state
    #
    # The downstream classifier MUST NOT mark a download "missing" just because
    # its client was unreachable, otherwise a brief client restart flags every
    # active download as failed.
    #
    # We pre-group the loaded downloads by `download_client` name and forward
    # the per-client map (keyed by `download_client_id`) to each adapter via
    # `opts[:downloads]`. Adapters that don't need it ignore the opt; the
    # debrid adapter consumes it to look up the Mydia `Download` row for the
    # R8 metadata merge without performing DB queries inside the behaviour
    # callback.
    downloads_by_client = group_downloads_by_client(downloads)

    clients
    |> Task.async_stream(
      fn client_config ->
        adapter = Client.Registry.lookup(client_config.type)
        config = config_to_map(client_config)
        client_downloads = Map.get(downloads_by_client, client_config.name, %{})

        try do
          case Client.list_torrents(adapter, config, downloads: client_downloads) do
            {:ok, torrents} ->
              torrents_map =
                torrents
                |> Enum.map(fn torrent -> {torrent.id, torrent} end)
                |> Map.new()

              {client_config.name, {:reachable, torrents_map}}

            {:error, error} ->
              Logger.warning(
                "Failed to fetch torrents from #{client_config.name}: #{inspect(error)}"
              )

              {client_config.name, :unreachable}
          end
        rescue
          # A buggy or mis-registered adapter (e.g. a module that doesn't
          # implement list_torrents/2) must not crash the caller — that would
          # take down the whole Downloads LiveView for every other client too.
          # Degrade to :unreachable, same as an explicit {:error, _}.
          exception ->
            Logger.error(
              "Adapter #{inspect(adapter)} for client #{client_config.name} " <>
                "(type=#{client_config.type}) raised: #{Exception.message(exception)}"
            )

            {client_config.name, :unreachable}
        end
      end,
      timeout: :infinity,
      max_concurrency: 10
    )
    |> Enum.reduce(%{}, fn
      {:ok, {client_name, result}}, acc -> Map.put(acc, client_name, result)
      _, acc -> acc
    end)
  end

  defp group_downloads_by_client(downloads) do
    Enum.reduce(downloads, %{}, fn download, acc ->
      case {download.download_client, download.download_client_id} do
        {nil, _} ->
          acc

        {_, nil} ->
          acc

        {client_name, client_id} ->
          Map.update(acc, client_name, %{client_id => download}, fn existing ->
            Map.put(existing, client_id, download)
          end)
      end
    end)
  end

  defp enrich_download_with_status(download, client_statuses) do
    case Map.get(client_statuses, download.download_client) do
      {:reachable, torrents_map} ->
        case Map.get(torrents_map, download.download_client_id) do
          nil ->
            # Client confirmed it doesn't have this torrent — genuinely missing.
            enrich_download_with_empty_status(download, false)

          torrent_status ->
            enrich_download_with_torrent_status(download, torrent_status)
        end

      :unreachable ->
        # Client is misbehaving (down, restarting, network blip). We can't tell
        # whether the torrent is there — DO NOT mark missing. Surface status as
        # "unknown" so DownloadMonitor's missing-handler skips it this cycle.
        enrich_download_with_unknown_status(download)

      nil ->
        # The client referenced by the download isn't configured at all (deleted,
        # renamed, or never existed) — treat as genuinely missing.
        enrich_download_with_empty_status(download)
    end
  end

  defp enrich_download_with_torrent_status(download, torrent_status) do
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
      client_failure_category: torrent_status.failure_category,
      client_error_detail: torrent_status.failure_detail,
      db_completed_at: download.completed_at,
      imported_at: download.imported_at,
      import_retry_count: download.import_retry_count,
      import_last_error: download.import_last_error,
      import_failure_reason: download.import_failure_reason,
      import_reported_path: download.import_reported_path,
      import_next_retry_at: download.import_next_retry_at,
      import_failed_at: download.import_failed_at,
      last_progress_at: download.last_progress_at,
      last_known_bytes: download.last_known_bytes,
      last_observed_at: download.last_observed_at,
      stalled_since: download.stalled_since,
      in_client?: true
    })
  end

  defp enrich_download_with_unknown_status(download) do
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
      # "unknown" intentionally avoids the "missing" / "failed" classifications.
      status: "unknown",
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
      db_completed_at: download.completed_at,
      imported_at: download.imported_at,
      import_retry_count: download.import_retry_count,
      import_last_error: download.import_last_error,
      import_failure_reason: download.import_failure_reason,
      import_reported_path: download.import_reported_path,
      import_next_retry_at: download.import_next_retry_at,
      import_failed_at: download.import_failed_at,
      last_progress_at: download.last_progress_at,
      last_known_bytes: download.last_known_bytes,
      # Carry the persisted stall state through an outage. The soft-stall badge
      # itself is gated on status == "downloading", so it isn't shown while the
      # client is unreachable (status "unknown"); preserving these fields keeps
      # the state intact for clearing/recovery once the client is reachable again.
      last_observed_at: download.last_observed_at,
      stalled_since: download.stalled_since,
      # Client unreachable — presence indeterminate.
      in_client?: nil
    })
  end

  defp enrich_download_with_empty_status(download, in_client? \\ nil) do
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
      import_failure_reason: download.import_failure_reason,
      import_reported_path: download.import_reported_path,
      import_next_retry_at: download.import_next_retry_at,
      import_failed_at: download.import_failed_at,
      last_progress_at: download.last_progress_at,
      last_known_bytes: download.last_known_bytes,
      last_observed_at: download.last_observed_at,
      stalled_since: download.stalled_since,
      in_client?: in_client?
    })
  end

  defp status_from_torrent_state(state) do
    case state do
      :downloading -> "downloading"
      :seeding -> "seeding"
      :completed -> "completed"
      :paused -> "paused"
      :checking -> "checking"
      :queued -> "queued"
      :error -> "failed"
      _ -> "unknown"
    end
  end

  defp apply_status_filters(downloads, :all), do: downloads

  defp apply_status_filters(downloads, :active) do
    Enum.filter(downloads, fn d ->
      # Active downloads are those that haven't been imported yet
      # and are currently downloading, seeding, checking, paused, or queued.
      # `queued` covers the debrid lifecycle phases where the provider is
      # waiting on the swarm or Mydia's local fetcher hasn't claimed the
      # ready job yet — without this they'd vanish from the queue tab.
      is_nil(d.imported_at) and
        d.status in ["downloading", "seeding", "checking", "paused", "queued"]
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
