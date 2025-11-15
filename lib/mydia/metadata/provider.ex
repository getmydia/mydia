defmodule Mydia.Metadata.Provider do
  @moduledoc """
  Behaviour for metadata provider adapters.

  This module defines the interface that all metadata provider implementations
  must implement. It provides a common abstraction for interacting with various
  metadata sources (TMDB, TVDB, metadata-relay, etc.).

  ## Implementing a new adapter

  To create a new metadata provider adapter, create a module that implements the
  `Mydia.Metadata.Provider` behaviour:

      defmodule Mydia.Metadata.Provider.MyProvider do
        @behaviour Mydia.Metadata.Provider

        @impl true
        def test_connection(config) do
          # Test if we can connect to the provider
          # Returns {:ok, info} or {:error, reason}
        end

        @impl true
        def search(config, query, opts \\\\ []) do
          # Search for media by title, year, etc.
          # Returns {:ok, [result]} or {:error, reason}
        end

        @impl true
        def fetch_by_id(config, provider_id, opts \\\\ []) do
          # Fetch detailed metadata by provider-specific ID
          # Returns {:ok, metadata} or {:error, reason}
        end

        @impl true
        def fetch_images(config, provider_id, opts \\\\ []) do
          # Fetch images (posters, backdrops) for media
          # Returns {:ok, images} or {:error, reason}
        end

        @impl true
        def fetch_season(config, provider_id, season_number, opts \\\\ []) do
          # Fetch season details with episode information
          # Returns {:ok, season} or {:error, reason}
        end
      end

  ## Configuration

  Each adapter receives a configuration map with connection details:

      config = %{
        type: :tmdb,  # or :tvdb, :metadata_relay, etc.
        api_key: "your_api_key",
        base_url: "https://api.themoviedb.org",
        # provider-specific options
        options: %{
          language: "en-US",
          include_adult: false
        }
      }

  ## Search Result Structure

  The `search/3` callback should return search result maps with the following structure:

      %{
        provider_id: "12345",
        provider: :tmdb,
        title: "The Matrix",
        original_title: "The Matrix",
        year: 1999,
        media_type: :movie | :tv_show,
        overview: "A computer hacker learns...",
        poster_path: "/poster.jpg",
        backdrop_path: "/backdrop.jpg",
        popularity: 123.45,
        vote_average: 8.7,
        vote_count: 12345
      }

  ## Metadata Structure

  The `fetch_by_id/3` callback should return detailed metadata maps:

      %{
        provider_id: "12345",
        provider: :tmdb,
        title: "The Matrix",
        original_title: "The Matrix",
        year: 1999,
        release_date: ~D[1999-03-31],
        media_type: :movie | :tv_show,
        overview: "A computer hacker learns...",
        tagline: "The fight for the future begins.",
        runtime: 136,  # minutes, for movies
        status: "Released",
        genres: ["Action", "Science Fiction"],
        poster_path: "/poster.jpg",
        backdrop_path: "/backdrop.jpg",
        popularity: 123.45,
        vote_average: 8.7,
        vote_count: 12345,
        imdb_id: "tt0133093",
        # TV show specific fields
        number_of_seasons: 5,
        number_of_episodes: 73,
        episode_run_time: [45],
        first_air_date: ~D[2013-09-23],
        last_air_date: ~D[2019-05-19],
        in_production: false,
        # Additional metadata
        production_companies: ["Warner Bros."],
        production_countries: ["US"],
        spoken_languages: ["en"],
        homepage: "https://example.com",
        cast: [
          %{name: "Keanu Reeves", character: "Neo", order: 0, profile_path: "/path.jpg"}
        ],
        crew: [
          %{name: "Lana Wachowski", job: "Director", department: "Directing"}
        ],
        alternative_titles: ["The Matrix Reloaded", "Matrix"]
      }

  ## Images Structure

  The `fetch_images/3` callback should return an `ImagesResponse` struct:

      %ImagesResponse{
        posters: [
          %ImageData{file_path: "/poster1.jpg", width: 2000, height: 3000, aspect_ratio: 0.667, vote_average: 5.4, vote_count: 12}
        ],
        backdrops: [
          %ImageData{file_path: "/backdrop1.jpg", width: 3840, height: 2160, aspect_ratio: 1.778, vote_average: 5.3, vote_count: 8}
        ],
        logos: [
          %ImageData{file_path: "/logo1.png", width: 500, height: 200, aspect_ratio: 2.5}
        ]
      }

  ## Season Structure

  The `fetch_season/4` callback should return season metadata:

      %{
        season_number: 1,
        name: "Season 1",
        overview: "The first season...",
        air_date: ~D[2013-09-23],
        poster_path: "/season_poster.jpg",
        episode_count: 13,
        episodes: [
          %{
            episode_number: 1,
            name: "Pilot",
            overview: "A chemistry teacher...",
            air_date: ~D[2013-09-23],
            runtime: 58,
            still_path: "/episode_still.jpg",
            vote_average: 8.2,
            vote_count: 543
          }
        ]
      }
  """

  alias Mydia.Metadata.Provider.Error

  @type config :: %{
          type: atom(),
          api_key: String.t() | nil,
          base_url: String.t(),
          options: map()
        }

  alias Mydia.Metadata.Structs.{
    CastMember,
    CrewMember,
    EpisodeData,
    ImageData,
    ImagesResponse,
    MediaMetadata,
    SearchResult,
    SeasonData
  }

  @type media_type :: :movie | :tv_show

  @type search_result :: SearchResult.t()

  @type metadata :: MediaMetadata.t()

  @type cast_member :: CastMember.t()

  @type crew_member :: CrewMember.t()

  @type image :: ImageData.t()

  @type images :: ImagesResponse.t()

  @type episode :: EpisodeData.t()

  @type season :: SeasonData.t()

  @type search_opts :: [
          media_type: media_type(),
          year: integer(),
          language: String.t(),
          include_adult: boolean(),
          page: integer()
        ]

  @type fetch_opts :: [
          language: String.t(),
          append_to_response: [String.t()]
        ]

  @type image_opts :: [
          language: String.t(),
          include_image_language: [String.t()]
        ]

  @type season_opts :: [
          language: String.t()
        ]

  @type trending_opts :: [
          language: String.t(),
          page: integer()
        ]

  @doc """
  Tests the connection to the metadata provider.

  Returns `{:ok, info}` where info is a map containing provider information
  (version, status, etc.) if successful, or `{:error, reason}` if the
  connection fails.

  ## Examples

      iex> test_connection(config)
      {:ok, %{status: "ok", version: "3"}}

      iex> test_connection(bad_config)
      {:error, %Error{type: :connection_failed, message: "Connection refused"}}
  """
  @callback test_connection(config()) :: {:ok, map()} | {:error, Error.t()}

  @doc """
  Searches for media by title and optional parameters.

  Returns `{:ok, [search_result]}` with a list of matching media,
  or `{:error, reason}` if an error occurs.

  ## Options

    * `:media_type` - Filter by media type (`:movie`, `:tv_show`)
    * `:year` - Filter by release year
    * `:language` - Language for results (default: "en-US")
    * `:include_adult` - Whether to include adult content (default: false)
    * `:page` - Page number for pagination (default: 1)

  ## Examples

      iex> search(config, "The Matrix", year: 1999)
      {:ok, [%{provider_id: "603", title: "The Matrix", year: 1999, ...}]}

      iex> search(config, "Breaking Bad", media_type: :tv_show)
      {:ok, [%{provider_id: "1396", title: "Breaking Bad", media_type: :tv_show, ...}]}
  """
  @callback search(config(), query :: String.t(), search_opts()) ::
              {:ok, [search_result()]} | {:error, Error.t()}

  @doc """
  Fetches detailed metadata for a specific media item by provider ID.

  Returns `{:ok, metadata}` with complete metadata,
  or `{:error, reason}` if the media is not found or an error occurs.

  ## Options

    * `:language` - Language for results (default: "en-US")
    * `:append_to_response` - Additional data to include (e.g., ["credits", "images"])

  ## Examples

      iex> fetch_by_id(config, "603", media_type: :movie)
      {:ok, %{provider_id: "603", title: "The Matrix", year: 1999, runtime: 136, ...}}

      iex> fetch_by_id(config, "invalid_id", media_type: :movie)
      {:error, %Error{type: :not_found, message: "Media not found"}}
  """
  @callback fetch_by_id(config(), provider_id :: String.t(), fetch_opts()) ::
              {:ok, metadata()} | {:error, Error.t()}

  @doc """
  Fetches images for a specific media item.

  Returns `{:ok, images}` with poster, backdrop, and logo images,
  or `{:error, reason}` if an error occurs.

  ## Options

    * `:language` - Primary language for images
    * `:include_image_language` - Additional languages to include

  ## Examples

      iex> fetch_images(config, "603", media_type: :movie)
      {:ok, %ImagesResponse{posters: [...], backdrops: [...], logos: [...]}}
  """
  @callback fetch_images(config(), provider_id :: String.t(), image_opts()) ::
              {:ok, images()} | {:error, Error.t()}

  @doc """
  Fetches season details with episode information for a TV show.

  Returns `{:ok, season}` with season and episode metadata,
  or `{:error, reason}` if an error occurs.

  ## Options

    * `:language` - Language for results (default: "en-US")

  ## Examples

      iex> fetch_season(config, "1396", 1)
      {:ok, %{season_number: 1, episodes: [%{episode_number: 1, name: "Pilot", ...}]}}
  """
  @callback fetch_season(
              config(),
              provider_id :: String.t(),
              season_number :: integer(),
              season_opts()
            ) ::
              {:ok, season()} | {:error, Error.t()}

  @doc """
  Fetches trending media for a specific media type.

  Returns `{:ok, [search_result]}` with a list of trending media,
  or `{:error, reason}` if an error occurs.

  ## Options

    * `:media_type` - Media type to fetch (`:movie` or `:tv_show`, required)
    * `:language` - Language for results (default: "en-US")
    * `:page` - Page number for pagination (default: 1)

  ## Examples

      iex> fetch_trending(config, media_type: :movie)
      {:ok, [%{provider_id: "603", title: "The Matrix", ...}]}

      iex> fetch_trending(config, media_type: :tv_show)
      {:ok, [%{provider_id: "1396", title: "Breaking Bad", ...}]}
  """
  @callback fetch_trending(config(), trending_opts()) ::
              {:ok, [search_result()]} | {:error, Error.t()}
end
