defmodule Mydia.Downloads.Client do
  @moduledoc """
  Behaviour for download client adapters.

  This module defines the interface that all download client implementations
  must implement. It provides a common abstraction for interacting with various
  torrent clients (qBittorrent, Transmission, etc.).

  ## Implementing a new adapter

  To create a new download client adapter, create a module that implements the
  `Mydia.Downloads.Client` behaviour:

      defmodule Mydia.Downloads.Client.MyClient do
        @behaviour Mydia.Downloads.Client

        @impl true
        def test_connection(config) do
          # Test if we can connect to the client
          # Returns {:ok, version_info} or {:error, reason}
        end

        @impl true
        def add_torrent(config, torrent, opts \\\\ []) do
          # Add a torrent to the client
          # Returns {:ok, client_id} or {:error, reason}
        end

        @impl true
        def get_status(config, client_id) do
          # Get the status of a specific torrent
          # Returns {:ok, status_map} or {:error, reason}
        end

        @impl true
        def list_torrents(config, opts \\\\ []) do
          # List all torrents, optionally filtered
          # Returns {:ok, [status_map]} or {:error, reason}
        end

        @impl true
        def remove_torrent(config, client_id, opts \\\\ []) do
          # Remove a torrent from the client
          # Returns :ok or {:error, reason}
        end

        @impl true
        def pause_torrent(config, client_id) do
          # Pause a torrent
          # Returns :ok or {:error, reason}
        end

        @impl true
        def resume_torrent(config, client_id) do
          # Resume a paused torrent
          # Returns :ok or {:error, reason}
        end
      end

  ## Configuration

  Each adapter receives a configuration map with connection details:

      config = %{
        type: :qbittorrent,  # or :transmission, etc.
        host: "localhost",
        port: 8080,
        username: "admin",
        password: "adminpass",
        use_ssl: false,
        # adapter-specific options
        options: %{}
      }

  ## Status Map Structure

  The `get_status/2` and `list_torrents/2` callbacks should return status maps
  with the following structure:

      %{
        id: "client_specific_id",
        name: "torrent_name",
        state: :downloading | :seeding | :paused | :error | :completed,
        progress: 0.0..100.0,
        download_speed: 1234567,  # bytes/second
        upload_speed: 123456,      # bytes/second
        downloaded: 1234567890,    # bytes
        uploaded: 123456789,       # bytes
        size: 2345678901,          # bytes
        eta: 3600,                 # seconds remaining, or nil
        ratio: 1.5,                # upload/download ratio
        save_path: "/downloads/path",
        added_at: ~U[2024-01-01 00:00:00Z],
        completed_at: ~U[2024-01-01 01:00:00Z] | nil
      }
  """

  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Structs.{ClientInfo, TorrentStatus}

  @type config :: %{
          type: atom(),
          host: String.t(),
          port: integer(),
          username: String.t() | nil,
          password: String.t() | nil,
          use_ssl: boolean(),
          options: map()
        }

  @type torrent_input :: {:magnet, String.t()} | {:file, binary()} | {:url, String.t()}

  @type torrent_state :: :downloading | :seeding | :paused | :error | :completed | :checking

  @type status_map :: TorrentStatus.t()

  @type add_torrent_opts :: [
          category: String.t(),
          tags: [String.t()],
          save_path: String.t(),
          paused: boolean()
        ]

  @type remove_torrent_opts :: [
          delete_files: boolean()
        ]

  @type list_torrents_opts :: [
          filter: :all | :downloading | :seeding | :completed | :paused | :active | :inactive,
          category: String.t(),
          tag: String.t()
        ]

  @doc """
  Tests the connection to the download client.

  Returns `{:ok, info}` where info is a ClientInfo struct containing client
  information (version, api_version, etc.) if successful, or `{:error, reason}`
  if the connection fails.

  ## Examples

      iex> test_connection(config)
      {:ok, %ClientInfo{version: "v4.5.0", api_version: "2.8.19"}}

      iex> test_connection(bad_config)
      {:error, %Error{type: :connection_failed, message: "Connection refused"}}
  """
  @callback test_connection(config()) :: {:ok, ClientInfo.t()} | {:error, Error.t()}

  @doc """
  Adds a torrent to the download client.

  Accepts a torrent as a magnet link, file contents, or URL.

  Returns `{:ok, client_id}` with the client's internal ID for the torrent,
  or `{:error, reason}` if the operation fails.

  ## Options

    * `:category` - Category to assign to the torrent
    * `:tags` - List of tags to apply
    * `:save_path` - Custom download location
    * `:paused` - Whether to add the torrent in paused state (default: false)

  ## Examples

      iex> add_torrent(config, {:magnet, "magnet:?xt=..."}, category: "movies")
      {:ok, "abc123def456"}

      iex> add_torrent(config, {:file, file_contents})
      {:ok, "abc123def456"}

      iex> add_torrent(config, {:url, "https://example.com/file.torrent"})
      {:ok, "abc123def456"}
  """
  @callback add_torrent(config(), torrent_input(), add_torrent_opts()) ::
              {:ok, String.t()} | {:error, Error.t()}

  @doc """
  Gets the status of a specific torrent.

  Returns `{:ok, status_map}` with detailed information about the torrent,
  or `{:error, reason}` if the torrent is not found or an error occurs.

  ## Examples

      iex> get_status(config, "abc123")
      {:ok, %{id: "abc123", name: "My Torrent", state: :downloading, progress: 45.5, ...}}

      iex> get_status(config, "invalid_id")
      {:error, %Error{type: :not_found, message: "Torrent not found"}}
  """
  @callback get_status(config(), client_id :: String.t()) ::
              {:ok, status_map()} | {:error, Error.t()}

  @doc """
  Lists all torrents in the download client.

  Returns `{:ok, [status_map]}` with a list of status maps for all torrents
  matching the filter criteria, or `{:error, reason}` if an error occurs.

  ## Options

    * `:filter` - Filter torrents by state (`:all`, `:downloading`, `:seeding`, etc.)
    * `:category` - Filter by category
    * `:tag` - Filter by tag

  ## Examples

      iex> list_torrents(config)
      {:ok, [%{id: "abc123", ...}, %{id: "def456", ...}]}

      iex> list_torrents(config, filter: :downloading)
      {:ok, [%{id: "abc123", state: :downloading, ...}]}
  """
  @callback list_torrents(config(), list_torrents_opts()) ::
              {:ok, [status_map()]} | {:error, Error.t()}

  @doc """
  Removes a torrent from the download client.

  Returns `:ok` if the torrent was successfully removed, or `{:error, reason}`
  if an error occurs.

  ## Options

    * `:delete_files` - Whether to also delete downloaded files (default: false)

  ## Examples

      iex> remove_torrent(config, "abc123")
      :ok

      iex> remove_torrent(config, "abc123", delete_files: true)
      :ok

      iex> remove_torrent(config, "invalid_id")
      {:error, %Error{type: :not_found, message: "Torrent not found"}}
  """
  @callback remove_torrent(config(), client_id :: String.t(), remove_torrent_opts()) ::
              :ok | {:error, Error.t()}

  @doc """
  Pauses a torrent.

  Returns `:ok` if the torrent was successfully paused, or `{:error, reason}`
  if an error occurs.

  ## Examples

      iex> pause_torrent(config, "abc123")
      :ok
  """
  @callback pause_torrent(config(), client_id :: String.t()) :: :ok | {:error, Error.t()}

  @doc """
  Resumes a paused torrent.

  Returns `:ok` if the torrent was successfully resumed, or `{:error, reason}`
  if an error occurs.

  ## Examples

      iex> resume_torrent(config, "abc123")
      :ok
  """
  @callback resume_torrent(config(), client_id :: String.t()) :: :ok | {:error, Error.t()}

  ## Convenience Functions

  @doc """
  Tests connection to a download client using the specified adapter.
  """
  def test_connection(adapter, config) when is_atom(adapter) do
    adapter.test_connection(config)
  end

  @doc """
  Adds a torrent using the specified adapter.
  """
  def add_torrent(adapter, config, torrent, opts \\ []) when is_atom(adapter) do
    adapter.add_torrent(config, torrent, opts)
  end

  @doc """
  Gets torrent status using the specified adapter.
  """
  def get_status(adapter, config, client_id) when is_atom(adapter) do
    adapter.get_status(config, client_id)
  end

  @doc """
  Lists all torrents using the specified adapter.
  """
  def list_torrents(adapter, config, opts \\ []) when is_atom(adapter) do
    adapter.list_torrents(config, opts)
  end

  @doc """
  Removes a torrent/download using the specified adapter.
  """
  def remove_download(adapter, config, client_id, opts \\ []) when is_atom(adapter) do
    adapter.remove_torrent(config, client_id, opts)
  end

  @doc """
  Pauses a torrent using the specified adapter.
  """
  def pause_torrent(adapter, config, client_id) when is_atom(adapter) do
    adapter.pause_torrent(config, client_id)
  end

  @doc """
  Resumes a torrent using the specified adapter.
  """
  def resume_torrent(adapter, config, client_id) when is_atom(adapter) do
    adapter.resume_torrent(config, client_id)
  end
end
