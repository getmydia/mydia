defmodule Mydia.Indexers.Adapter do
  @moduledoc """
  Behaviour for indexer and search provider adapters.

  This module defines the interface that all indexer implementations must
  implement. It provides a common abstraction for interacting with various
  torrent indexers and search providers (Prowlarr, Jackett, direct indexers, etc.).

  ## Implementing a new adapter

  To create a new indexer adapter, create a module that implements the
  `Mydia.Indexers.Adapter` behaviour:

      defmodule Mydia.Indexers.Adapter.MyIndexer do
        @behaviour Mydia.Indexers.Adapter

        @impl true
        def test_connection(config) do
          # Test if we can connect to the indexer
          # Returns {:ok, info} or {:error, reason}
        end

        @impl true
        def search(config, query, opts \\\\ []) do
          # Search the indexer with the given query
          # Returns {:ok, [%SearchResult{}]} or {:error, reason}
        end

        @impl true
        def get_capabilities(config) do
          # Get the indexer's capabilities
          # Returns {:ok, capabilities_map} or {:error, reason}
        end
      end

  ## Configuration

  Each adapter receives a configuration map with connection details:

      config = %{
        type: :prowlarr,  # or :jackett, :nyaa, etc.
        name: "My Indexer",
        host: "localhost",
        port: 9696,
        api_key: "your_api_key",
        use_ssl: false,
        # adapter-specific options
        options: %{}
      }

  ## Search Options

  The `search/3` callback accepts the following options:

    * `:categories` - List of category IDs to search within
    * `:limit` - Maximum number of results to return
    * `:min_seeders` - Minimum number of seeders required
    * `:min_size` - Minimum file size in bytes
    * `:max_size` - Maximum file size in bytes

  ## Capabilities Map

  The `get_capabilities/2` callback should return a map with the following structure:

      %{
        searching: %{
          search: %{available: true, supported_params: ["q"]},
          tv_search: %{available: true, supported_params: ["q", "season", "ep"]},
          movie_search: %{available: true, supported_params: ["q", "imdbid"]}
        },
        categories: [
          %{id: 2000, name: "Movies"},
          %{id: 5000, name: "TV"}
        ]
      }
  """

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.SearchResult

  @type config :: %{
          type: atom(),
          name: String.t(),
          host: String.t(),
          port: integer(),
          api_key: String.t() | nil,
          use_ssl: boolean(),
          options: map()
        }

  @type search_opts :: [
          categories: [integer()],
          limit: integer(),
          min_seeders: integer(),
          min_size: integer(),
          max_size: integer()
        ]

  @type capabilities :: %{
          searching: %{
            search: %{available: boolean(), supported_params: [String.t()]},
            tv_search: %{available: boolean(), supported_params: [String.t()]},
            movie_search: %{available: boolean(), supported_params: [String.t()]}
          },
          categories: [%{id: integer(), name: String.t()}]
        }

  @doc """
  Tests the connection to the indexer.

  Returns `{:ok, info}` where info is a map containing indexer information
  if successful, or `{:error, reason}` if the connection fails.

  ## Examples

      iex> test_connection(config)
      {:ok, %{name: "Prowlarr", version: "1.0.0"}}

      iex> test_connection(bad_config)
      {:error, %Error{type: :connection_failed, message: "Connection refused"}}
  """
  @callback test_connection(config()) :: {:ok, map()} | {:error, Error.t()}

  @doc """
  Searches the indexer with the given query.

  Returns `{:ok, [%SearchResult{}]}` with a list of search results,
  or `{:error, reason}` if the search fails.

  ## Options

    * `:categories` - List of category IDs to search within (default: all)
    * `:limit` - Maximum number of results to return (default: 100)
    * `:min_seeders` - Minimum number of seeders required (default: 0)
    * `:min_size` - Minimum file size in bytes
    * `:max_size` - Maximum file size in bytes

  ## Examples

      iex> search(config, "Ubuntu")
      {:ok, [%SearchResult{title: "Ubuntu 22.04", ...}, ...]}

      iex> search(config, "Ubuntu", categories: [2000], min_seeders: 5)
      {:ok, [%SearchResult{...}]}

      iex> search(config, "Invalid query")
      {:error, %Error{type: :search_failed, message: "No results found"}}
  """
  @callback search(config(), query :: String.t(), search_opts()) ::
              {:ok, [SearchResult.t()]} | {:error, Error.t()}

  @doc """
  Gets the indexer's capabilities.

  Returns `{:ok, capabilities}` with information about what the indexer
  supports, or `{:error, reason}` if the request fails.

  ## Examples

      iex> get_capabilities(config)
      {:ok, %{
        searching: %{
          search: %{available: true, supported_params: ["q"]},
          tv_search: %{available: true, supported_params: ["q", "season", "ep"]}
        },
        categories: [%{id: 2000, name: "Movies"}]
      }}
  """
  @callback get_capabilities(config()) :: {:ok, capabilities()} | {:error, Error.t()}
end
