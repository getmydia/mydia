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
  alias Mydia.Downloads.{TorrentParser, TorrentMatcher}
  alias Mydia.Settings

  @doc """
  Finds untracked torrents in download clients and attempts to match them with library items.

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

    # Attempt to match and create downloads for untracked torrents
    untracked
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
      clients
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
    adapter = get_adapter_module(client_config.type)
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
    # Build sets for both (client_name, client_id) pairs and titles
    # This prevents duplicates when client IDs are reused after torrents are removed
    tracked_by_id =
      tracked_downloads
      |> Enum.map(fn d -> {d.download_client, d.download_client_id} end)
      |> MapSet.new()

    tracked_by_title =
      tracked_downloads
      |> Enum.map(fn d -> String.downcase(d.title) end)
      |> MapSet.new()

    # Filter out torrents that are already tracked by either ID or title
    Enum.reject(client_torrents, fn torrent ->
      MapSet.member?(tracked_by_id, {torrent.client_name, torrent.id}) or
        MapSet.member?(tracked_by_title, String.downcase(torrent.name))
    end)
  end

  defp process_untracked_torrent(torrent) do
    Logger.debug("Processing untracked torrent: #{torrent.name}")

    with {:ok, parsed_info} <- TorrentParser.parse(torrent.name),
         {:ok, match} <- TorrentMatcher.find_match(parsed_info),
         {:ok, download} <- create_download_record(torrent, match, parsed_info) do
      Logger.info(
        "Successfully matched and tracked torrent: #{torrent.name} -> #{match.media_item.title}",
        torrent_id: torrent.id,
        client: torrent.client_name,
        media_item_id: match.media_item.id,
        confidence: match.confidence
      )

      {:ok, download}
    else
      {:error, :unable_to_parse} ->
        Logger.debug("Unable to parse torrent name: #{torrent.name}")
        {:error, :parse_failed}

      {:error, :no_match_found} ->
        Logger.debug("No library match found for torrent: #{torrent.name}")
        {:error, :no_match}

      {:error, :episode_not_found} ->
        Logger.debug("Episode not found in library for torrent: #{torrent.name}")
        {:error, :episode_not_found}

      {:error, reason} ->
        Logger.warning("Failed to process untracked torrent: #{inspect(reason)}",
          torrent_name: torrent.name
        )

        {:error, reason}
    end
  end

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
        seeders: torrent[:seeders],
        leechers: torrent[:leechers],
        quality: parsed_info[:quality],
        source: parsed_info[:source],
        codec: parsed_info[:codec],
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

  defp get_adapter_module(:qbittorrent), do: Mydia.Downloads.Client.Qbittorrent
  defp get_adapter_module(:transmission), do: Mydia.Downloads.Client.Transmission
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
      options: config.connection_settings || %{}
    }
  end
end
