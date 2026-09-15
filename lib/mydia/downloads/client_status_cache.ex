defmodule Mydia.Downloads.ClientStatusCache do
  @moduledoc """
  The last torrent listing each download client answered with.

  `Mydia.Downloads.History` stores an entry whenever a client answers a status
  poll, and reads it back when a page asked for a bounded poll and the client did
  not answer in time. Transmission answers nothing while it deletes a large
  torrent's data; a page that waited on it froze for as long as the delete took.

  Same shape as `Mydia.Downloads.ExternalTorrents`: the GenServer owns the named
  table and nothing else, so no read or write goes through a process a hung
  client could block.
  """

  use GenServer

  @table_name :download_client_status_cache

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores `torrents_map` (torrent id to `DownloadStatus`) as `client_name`'s
  latest answer.
  """
  @spec put(String.t(), map(), DateTime.t()) :: :ok
  def put(client_name, torrents_map, fetched_at \\ DateTime.utc_now()) do
    :ets.insert(@table_name, {client_name, torrents_map, fetched_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  The latest answer stored for `client_name` and when it was taken, or nil.
  Never performs I/O.
  """
  @spec get(String.t()) :: {map(), DateTime.t()} | nil
  def get(client_name) do
    case :ets.lookup(@table_name, client_name) do
      [{^client_name, torrents_map, fetched_at}] -> {torrents_map, fetched_at}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
