defmodule Mydia.Downloads.ExternalTorrents do
  @moduledoc """
  Torrents that live in a download client but do not belong to Mydia.

  Derived on every scan and never written to the database. A torrent qualifies
  when it is in a configured torrent client and Mydia has neither a download row
  for it nor imported files carrying its provenance. Both subtractions matter:

    * download rows survive import with `imported_at` stamped, so a seeding
      torrent Mydia imported is still tracked
    * "Clear Completed" deletes download rows, so a still-seeding torrent whose
      row was cleared is recognisable only by the `(download_client,
      download_client_id)` pair on its imported files

  Results are cached in ETS. `get/0` reads the cache and never performs I/O;
  `refresh/0` performs the scan in the caller's process and stores it. The
  GenServer owns the table and nothing else, so a hung client can never block a
  reader.

  Modelled on `Mydia.Downloads.ClientHealth`, which uses the same
  GenServer-plus-named-ETS shape in this domain.
  """

  use GenServer

  require Logger

  alias Mydia.Downloads
  alias Mydia.Downloads.ExternalTorrents.Classifier
  alias Mydia.Downloads.Structs.{CandidatePool, DownloadStatus, ExternalScan, ExternalTorrent}
  alias Mydia.Library
  alias Mydia.Settings
  alias Phoenix.PubSub

  @table_name :external_torrents_scan
  @cache_key :scan

  # Usenet, debrid, and blackhole clients have no concept of a foreign torrent
  # sitting in them, so they are never scanned. Mirrors the filter that
  # UntrackedMatcher.fetch_all_client_torrents/0 applies.
  @torrent_client_types [:qbittorrent, :transmission, :rqbit]

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reads the cached scan. Never performs I/O.

  Returns `ExternalScan.empty()` when no scan has landed yet, including when the
  GenServer is not running (some test environments).
  """
  @spec get() :: ExternalScan.t()
  def get do
    case :ets.lookup(@table_name, @cache_key) do
      [{@cache_key, %ExternalScan{} = scan}] -> scan
      _ -> ExternalScan.empty()
    end
  rescue
    ArgumentError -> ExternalScan.empty()
  end

  @doc """
  Stores a scan in the cache.
  """
  @spec put(ExternalScan.t()) :: :ok
  def put(%ExternalScan{} = scan) do
    :ets.insert(@table_name, {@cache_key, scan})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Looks up one torrent by its derived id across both lists of the cached scan.

  Returns nil when the id is stale, which happens when the torrent left the
  client between render and click. Callers should treat nil as "it is gone" and
  tell the user so rather than raising.
  """
  @spec find(String.t()) :: ExternalTorrent.t() | nil
  def find(id) when is_binary(id) do
    scan = get()

    Enum.find(scan.needs_matching ++ scan.external, &(&1.id == id))
  end

  @doc """
  Scans every torrent client, stores the result, and broadcasts.
  """
  @spec refresh() :: ExternalScan.t()
  def refresh do
    scan = scan()
    put(scan)
    PubSub.broadcast(Mydia.PubSub, "downloads", :external_scan_updated)
    scan
  end

  @doc """
  Performs the scan without touching the cache.
  """
  @spec scan() :: ExternalScan.t()
  def scan do
    {listings, failed_clients} = fetch_all()

    {needs_matching, external} =
      listings
      |> subtract_known()
      |> Classifier.classify(CandidatePool.load())

    %ExternalScan{
      needs_matching: needs_matching,
      external: external,
      scanned_at: DateTime.utc_now(),
      failed_clients: failed_clients
    }
  end

  @doc """
  Drops every listed torrent Mydia already tracks or has already imported.

  Flattens `{client_name, [status]}` listings into `{client_name, status}`
  entries so the classifier never has to know about client grouping.
  """
  @spec subtract_known([{String.t(), [DownloadStatus.t()]}]) ::
          [{String.t(), DownloadStatus.t()}]
  def subtract_known(listings) do
    tracked = Downloads.tracked_client_pairs()

    untracked =
      for {client_name, statuses} <- listings,
          %DownloadStatus{} = status <- statuses,
          not MapSet.member?(tracked, {client_name, status.id}) do
        {client_name, status}
      end

    # One query for the whole batch rather than one per torrent: this runs on
    # every scan, over every foreign torrent in every client.
    imported =
      untracked
      |> Enum.map(fn {client_name, status} -> {client_name, status.id} end)
      |> Library.imported_torrent_pairs()

    Enum.reject(untracked, fn {client_name, status} ->
      MapSet.member?(imported, {client_name, status.id})
    end)
  end

  ## GenServer

  @impl true
  def init(_opts) do
    # No I/O here: the table must exist before the first reader, and scanning
    # would hit the database and every client during application boot.
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  ## Private

  defp fetch_all do
    clients =
      Settings.list_download_client_configs()
      |> Enum.filter(&(&1.enabled and &1.type in @torrent_client_types))

    results =
      clients
      |> Task.async_stream(&fetch_one/1, timeout: :infinity, max_concurrency: 10)
      # async_stream preserves input order, so zipping recovers which client a
      # crashed task belonged to. Without this a crash would be reported to the
      # operator as a client literally named "unknown".
      |> Enum.zip(clients)
      |> Enum.map(fn
        {{:ok, result}, _config} ->
          result

        {{:exit, reason}, config} ->
          Logger.warning("Listing torrents from #{config.name} crashed: #{inspect(reason)}")
          {:error, config.name}
      end)

    listings = for {:ok, client_name, statuses} <- results, do: {client_name, statuses}
    failed = for {:error, client_name} <- results, do: client_name

    {listings, failed}
  end

  defp fetch_one(config) do
    adapter = Downloads.Client.Registry.lookup(config.type)

    case Downloads.Client.list_torrents(adapter, config_to_map(config), []) do
      {:ok, statuses} ->
        {:ok, config.name, statuses}

      {:error, error} ->
        Logger.warning("Failed to list torrents from #{config.name}: #{inspect(error)}")
        {:error, config.name}
    end
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
