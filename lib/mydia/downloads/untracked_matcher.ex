defmodule Mydia.Downloads.UntrackedMatcher do
  @moduledoc """
  Detects and matches manually-added torrents from download clients with library items.

  This module enables automatic tracking and import of torrents that users
  add directly to their download clients (bypassing Mydia's search interface).

  ## Duplicate Prevention

  To prevent creating duplicate download records, torrents are matched against
  existing downloads using two criteria:
  - Client ID pair (client_name, client_id)
  - Torrent title (case-insensitive)

  This dual-matching prevents issues when download clients reuse numeric IDs
  after torrents are removed from the client.
  """

  require Logger
  alias Mydia.Downloads
  alias Mydia.Downloads.{ReleaseIntake, TorrentMatcher}
  alias Mydia.Library
  alias Mydia.Library.Structs.Quality
  alias Mydia.Settings

  @doc """
  Finds untracked torrents in download clients and attempts to match them with library items.

  Matches against ALL library items (both monitored and unmonitored) since users may
  manually add torrents for shows they haven't marked as monitored yet.

  Returns a list of successfully created download records.
  """
  def find_and_match_untracked do
    Logger.info("Searching for untracked torrents in download clients")

    # Get all torrents from all clients
    client_torrents = fetch_all_client_torrents()

    # Get all tracked downloads from database
    tracked_downloads = Downloads.list_downloads()

    # Find torrents that aren't tracked in our database
    untracked = find_untracked_torrents(client_torrents, tracked_downloads)

    Logger.info("Found #{length(untracked)} untracked torrent(s)")

    # Filter out torrents that have already been imported to the library
    # (completed downloads that are now seeding)
    not_imported = filter_already_imported_torrents(untracked)

    Logger.info(
      "#{length(not_imported)} torrent(s) not yet imported (#{length(untracked) - length(not_imported)} already in library)"
    )

    # Attempt to match and create downloads for untracked torrents
    not_imported
    |> Enum.map(&process_untracked_torrent/1)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, download} -> download end)
  end

  ## Private Functions

  defp fetch_all_client_torrents do
    clients = get_configured_clients()

    if clients == [] do
      Logger.warning("No download clients configured")
      []
    else
      # Only fetch torrents from torrent clients (not Usenet or HTTP clients)
      torrent_clients =
        Enum.filter(clients, fn client ->
          client.type in [:qbittorrent, :transmission, :rqbit]
        end)

      torrent_clients
      |> Task.async_stream(
        &fetch_client_torrents/1,
        timeout: :infinity,
        max_concurrency: 10
      )
      |> Enum.flat_map(fn
        {:ok, torrents} -> torrents
        _ -> []
      end)
    end
  end

  defp fetch_client_torrents(client_config) do
    adapter = Downloads.Client.Registry.lookup(client_config.type)
    config = config_to_map(client_config)

    case Downloads.Client.list_torrents(adapter, config, []) do
      {:ok, torrents} ->
        # Attach client name to each torrent for later reference
        Enum.map(torrents, fn torrent ->
          Map.put(torrent, :client_name, client_config.name)
        end)

      {:error, error} ->
        Logger.warning("Failed to fetch torrents from #{client_config.name}: #{inspect(error)}")
        []
    end
  end

  defp find_untracked_torrents(client_torrents, tracked_downloads) do
    # Build set of (client_name, client_id) pairs for tracked downloads
    # Using hash-based IDs ensures stable identification without reuse issues
    tracked_by_id =
      tracked_downloads
      |> Enum.map(fn d -> {d.download_client, d.download_client_id} end)
      |> MapSet.new()

    # Filter out torrents that are already tracked by ID
    Enum.reject(client_torrents, fn torrent ->
      MapSet.member?(tracked_by_id, {torrent.client_name, torrent.id})
    end)
  end

  defp filter_already_imported_torrents(torrents) do
    Enum.reject(torrents, fn torrent ->
      imported? = Library.torrent_already_imported?(torrent.client_name, torrent.id)

      if imported? do
        Logger.debug("Skipping already-imported torrent: #{torrent.name}",
          client: torrent.client_name,
          client_id: torrent.id
        )
      end

      imported?
    end)
  end

  @doc false
  # Public for testing the parse/match/route decision in isolation. Not part of
  # the module's intended API — callers use find_and_match_untracked/0.
  def process_untracked_torrent(torrent) do
    Logger.debug("Processing untracked torrent: #{torrent.name}")

    with {:ok, parsed_info} <- ReleaseIntake.parse_release(torrent.name),
         {:ok, match} <- TorrentMatcher.find_match(parsed_info, monitored_only: false) do
      case create_download_record(torrent, match, parsed_info) do
        {:ok, download} ->
          Logger.info(
            "Successfully matched and tracked torrent: #{torrent.name} -> #{match.media_item.title}",
            torrent_id: torrent.id,
            client: torrent.client_name,
            media_item_id: match.media_item.id,
            confidence: match.confidence
          )

          {:ok, download}

        {:error, reason} ->
          Logger.warning("Failed to create download record: #{inspect(reason)}",
            torrent_name: torrent.name
          )

          {:error, reason}
      end
    else
      # No library match, an unparseable name, or a validator rejection
      # (malicious / fake / password / etc.). Nothing is written: the torrent is
      # surfaced by Mydia.Downloads.ExternalTorrents, which derives it from the
      # client on every scan. No grab is ever triggered either — the torrent
      # already lives in the client.
      {:error, reason} ->
        Logger.debug("No library match for torrent (#{inspect(reason)}): #{torrent.name}")
        {:error, :no_library_match}
    end
  end

  # ParsedFileInfo nests quality in a %Quality{} struct; pull a scalar field
  # (resolution/source/codec) for flat metadata storage.
  defp quality_field(%{quality: %Quality{} = quality}, field), do: Map.get(quality, field)
  defp quality_field(_parsed_info, _field), do: nil

  defp create_download_record(torrent, match, parsed_info) do
    attrs = %{
      indexer: "manual",
      title: torrent.name,
      download_url: nil,
      download_client: torrent.client_name,
      download_client_id: torrent.id,
      media_item_id: match.media_item.id,
      episode_id: match.episode && match.episode.id,
      metadata: %{
        size: torrent.size,
        seeders: Map.get(torrent, :seeders),
        leechers: Map.get(torrent, :leechers),
        quality: quality_field(parsed_info, :resolution),
        source: quality_field(parsed_info, :source),
        codec: quality_field(parsed_info, :codec),
        matched_from_client: true,
        match_confidence: match.confidence,
        match_reason: match.match_reason
      }
    }

    Downloads.create_download(attrs)
  end

  ## Private Helpers

  defp get_configured_clients do
    Settings.list_download_client_configs()
    |> Enum.filter(& &1.enabled)
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
      options: config.connection_settings || %{}
    }
  end
end
