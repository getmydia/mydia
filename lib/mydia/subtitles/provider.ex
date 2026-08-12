defmodule Mydia.Subtitles.Provider do
  @moduledoc """
  Behaviour for subtitle provider adapters.

  This module defines the interface that all subtitle provider implementations
  must implement. It provides a common abstraction for interacting with various
  subtitle sources (metadata-relay, direct OpenSubtitles, etc.).

  ## Implementing a new provider

  To create a new subtitle provider adapter, create a module that implements the
  `Mydia.Subtitles.Provider` behaviour:

      defmodule Mydia.Subtitles.Provider.MyProvider do
        @behaviour Mydia.Subtitles.Provider

        @impl true
        def search(provider, params) do
          # Search for subtitles by hash, IMDB ID, etc.
          # Returns {:ok, [search_result]} or {:error, reason}
        end

        @impl true
        def download(provider, subtitle_info) do
          # Download subtitle file content
          # Returns {:ok, binary()} or {:error, reason}
        end

        @impl true
        def validate_config(config) do
          # Test provider configuration
          # Returns {:ok, validated_config} or {:error, reason}
        end

        @impl true
        def quota_info(provider) do
          # Get current quota status
          # Returns {:ok, quota_info} or {:error, reason}
        end
      end

  ## Provider Configuration

  Each provider is represented by a map (or database record) containing:

      %{
        id: "provider-uuid",
        user_id: "user-uuid",
        name: "My OpenSubtitles Account",
        type: :relay | :opensubtitles,
        enabled: true,
        priority: 1,
        credentials: %{
          # Provider-specific credentials
          username: "user@example.com",
          password: "encrypted_password",
          api_key: "api_key_value"
        },
        options: %{
          # Provider-specific options
        }
      }

  ## Search Parameters

  The `search/2` callback receives a map with search criteria:

      %{
        languages: "en,es,fr",
        file_hash: "8e245d9679d31e12",  # OpenSubtitles moviehash
        file_size: 742086656,            # bytes
        imdb_id: "816692",               # without "tt" prefix
        tmdb_id: "1396",
        media_type: "movie" | "episode",
        season_number: 1,                # for episodes
        episode_number: 5,               # for episodes
        query: "The Matrix"              # text search fallback
      }

  ## Search Result Format

  The `search/2` callback returns a list of maps in standardized format:

      [
        %{
          file_id: 12345,
          language: "en",
          format: "srt",
          subtitle_hash: "abc123...",
          rating: 8.5,
          download_count: 5432,
          hearing_impaired: false,
          moviehash_match: true,
          file_name: "The.Matrix.1999.srt"
        }
      ]

  ## Download Result

  The `download/2` callback returns the raw subtitle file content:

      {:ok, "1\\n00:00:01,000 --> 00:00:05,000\\nSubtitle text here\\n\\n2\\n..."}

  ## Quota Information

  The `quota_info/1` callback returns current quota status:

      # For relay providers (unlimited):
      {:ok, %{
        type: :unlimited,
        provider_type: :relay
      }}

      # For direct OpenSubtitles providers:
      {:ok, %{
        type: :limited,
        provider_type: :opensubtitles,
        remaining: 142,
        total: 200,
        reset_at: ~U[2024-01-01 00:00:00Z],
        vip: false
      }}

  ## Error Handling

  All callbacks should return `{:error, reason}` tuples for failures:

      {:error, :authentication_failed}
      {:error, :quota_exceeded}
      {:error, :not_found}
      {:error, :service_unavailable}
      {:error, {:http_error, 500, body}}
  """

  alias Mydia.Subtitles.Provider.{SearchResult, QuotaInfo}

  @type provider :: map()
  @type search_params :: %{
          required(:languages) => String.t(),
          optional(:file_hash) => String.t(),
          optional(:file_size) => integer(),
          optional(:imdb_id) => String.t(),
          optional(:tmdb_id) => String.t(),
          optional(:media_type) => String.t(),
          optional(:season_number) => integer(),
          optional(:episode_number) => integer(),
          optional(:query) => String.t()
        }

  @type subtitle_info :: %{
          file_id: integer() | String.t(),
          language: String.t(),
          format: String.t(),
          subtitle_hash: String.t()
        }

  @type search_result :: SearchResult.t()
  @type quota_info :: QuotaInfo.t()

  @doc """
  Searches for subtitles based on the provided criteria.

  Returns `{:ok, [search_result]}` with a list of matching subtitles in
  standardized format, or `{:error, reason}` if an error occurs.

  ## Parameters

    * `provider` - Provider configuration map with credentials and options
    * `params` - Search parameters map (see module documentation)

  ## Examples

      iex> search(provider, %{imdb_id: "816692", languages: "en"})
      {:ok, [%SearchResult{file_id: 12345, language: "en", ...}]}

      iex> search(provider, %{file_hash: "abc123", file_size: 123456, languages: "en,es"})
      {:ok, [%SearchResult{file_id: 12345, moviehash_match: true, ...}]}

  """
  @callback search(provider(), search_params()) ::
              {:ok, [search_result()]} | {:error, term()}

  @doc """
  Downloads a subtitle file and returns its content as binary.

  Returns `{:ok, content}` with the raw subtitle file content (SRT, ASS, VTT, etc.),
  or `{:error, reason}` if the download fails.

  ## Parameters

    * `provider` - Provider configuration map with credentials and options
    * `subtitle_info` - Map with file_id and other metadata from search results

  ## Examples

      iex> download(provider, %{file_id: 12345, language: "en", format: "srt"})
      {:ok, "1\\n00:00:01,000 --> 00:00:05,000\\nSubtitle text\\n"}

      iex> download(provider, %{file_id: 999999, language: "en"})
      {:error, :not_found}

  """
  @callback download(provider(), subtitle_info()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  Validates provider configuration and tests connectivity.

  This callback is used when users add or update provider configurations.
  It should verify that credentials are valid, test the connection to the
  service, and return additional provider information.

  Returns `{:ok, info}` with provider details if validation succeeds,
  or `{:error, reason}` if validation fails.

  ## Parameters

    * `config` - Provider configuration map to validate

  ## Returns

  The validated config map may include additional fields discovered during
  validation:

      %{
        valid: true,
        quota: %QuotaInfo{},
        version: "1.0",
        features: [:hash_search, :metadata_search]
      }

  ## Examples

      iex> validate_config(%{type: :opensubtitles, credentials: %{api_key: "valid"}})
      {:ok, %{valid: true, quota: %QuotaInfo{remaining: 200, ...}, vip: false}}

      iex> validate_config(%{type: :opensubtitles, credentials: %{api_key: "invalid"}})
      {:error, :authentication_failed}

  """
  @callback validate_config(config :: map()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Returns current quota information for the provider.

  Relay providers return unlimited quota, while direct OpenSubtitles providers
  return their current download quota status.

  Returns `{:ok, quota_info}` with quota details, or `{:error, reason}` if
  the quota cannot be retrieved.

  ## Parameters

    * `provider` - Provider configuration map

  ## Examples

      # Relay provider (unlimited)
      iex> quota_info(relay_provider)
      {:ok, %QuotaInfo{type: :unlimited, provider_type: :relay}}

      # OpenSubtitles free account
      iex> quota_info(os_provider)
      {:ok, %QuotaInfo{
        type: :limited,
        provider_type: :opensubtitles,
        remaining: 142,
        total: 200,
        reset_at: ~U[2024-01-01 00:00:00Z],
        vip: false
      }}

      # OpenSubtitles VIP account
      iex> quota_info(vip_provider)
      {:ok, %QuotaInfo{
        type: :limited,
        provider_type: :opensubtitles,
        remaining: 892,
        total: 1000,
        vip: true
      }}

  """
  @callback quota_info(provider()) ::
              {:ok, quota_info()} | {:error, term()}

  @doc """
  Describes what this provider can answer.

  The chain uses this to skip providers that cannot serve a query at all, rather
  than spending a request and a full timeout rediscovering it. Gestdown, for
  example, serves episodes keyed on a TVDB id and nothing else.
  """
  @callback capabilities() :: %{
              media_types: [:movie | :episode],
              search_keys: [:file_hash | :imdb_id | :tmdb_id | :tvdb_id | :query],
              requires_credentials: boolean(),
              quota: :unlimited | :limited
            }
end
