defmodule Mydia.MetadataStubProvider do
  @moduledoc """
  Deterministic in-memory metadata provider for tests.

  Registered under `:metadata_relay` by `Mydia.MetadataStub.setup_metadata_stub/1`,
  which is the only seam that reaches both guest search and admin approval.
  `AdminRequestsLive.Index` calls `MediaRequests.approve_request/2` without a
  config, so injecting a Bypass config cannot cover the approval path.

  The catalog is deliberately tiny and self-consistent: every id `search/3`
  returns is resolvable by `fetch_by_id/3`, because approval re-fetches by that
  id. A catalog that violates this reproduces the original defect, where the
  test seeded an id the relay had never heard of and the approval silently
  failed.
  """

  @behaviour Mydia.Metadata.Provider

  alias Mydia.Metadata.Provider.Error

  alias Mydia.Metadata.Structs.{
    EpisodeData,
    ImagesResponse,
    MediaMetadata,
    SearchResult,
    SeasonData,
    SeasonInfo
  }

  @movie_tmdb_id 550
  @series_tvdb_id 81_189
  @missing_id 999_999

  @movie_title "Stub Movie"
  @series_title "Stub Series"

  @doc "TMDB id of the catalog movie."
  def movie_tmdb_id, do: @movie_tmdb_id

  @doc "TVDB id of the catalog series."
  def series_tvdb_id, do: @series_tvdb_id

  @doc "Reserved id whose fetch always fails, for the approval-failure case."
  def missing_id, do: @missing_id

  @doc "Title of the catalog movie."
  def movie_title, do: @movie_title

  @doc "Title of the catalog series."
  def series_title, do: @series_title

  @impl true
  def test_connection(_config), do: {:ok, %{status: "ok"}}

  @impl true
  def search(_config, _query, opts) do
    case Keyword.get(opts, :media_type) do
      :tv_show -> {:ok, [series_search_result()]}
      _ -> {:ok, [movie_search_result()]}
    end
  end

  @impl true
  def fetch_by_id(_config, provider_id, opts) do
    cond do
      provider_id == to_string(@missing_id) ->
        {:error, Error.not_found("Media not found: #{@missing_id}")}

      Keyword.get(opts, :provider) == :tvdb or Keyword.get(opts, :media_type) == :tv_show ->
        {:ok, series_metadata()}

      true ->
        {:ok, movie_metadata()}
    end
  end

  @impl true
  def fetch_images(_config, _provider_id, _opts) do
    {:ok, ImagesResponse.new(%{posters: [], backdrops: [], logos: []})}
  end

  @impl true
  def fetch_season(_config, _provider_id, season_number, _opts) do
    {:ok,
     %SeasonData{
       season_number: season_number,
       name: "Season #{season_number}",
       overview: "Stub season.",
       episode_count: 2,
       episodes: [
         %EpisodeData{
           season_number: season_number,
           episode_number: 1,
           name: "Stub Episode One",
           overview: "First stub episode.",
           runtime: 42
         },
         %EpisodeData{
           season_number: season_number,
           episode_number: 2,
           name: "Stub Episode Two",
           overview: "Second stub episode.",
           runtime: 42
         }
       ]
     }}
  end

  @impl true
  def fetch_trending(_config, _opts), do: {:ok, []}

  ## Catalog

  defp movie_search_result do
    %SearchResult{
      provider_id: to_string(@movie_tmdb_id),
      provider: :metadata_relay,
      media_type: :movie,
      id: @movie_tmdb_id,
      title: @movie_title,
      original_title: @movie_title,
      # `year` is set explicitly rather than left for a caller to derive from
      # release_date: this struct is built as a literal, so nothing normalizes
      # it, and MetadataMatcher.calculate_movie_match_score/2 reads
      # `result.year` directly. A nil year costs the year bonus and lands the
      # score on 0.7999999999999999, just under FileIngest's 0.8 auto-link
      # threshold, which silently turns every "confident match" test into a
      # "cached candidate" one.
      year: 1999,
      release_date: "1999-03-30",
      overview: "A stub movie used by the guest request tests.",
      poster_path: "/stub-movie-poster.jpg",
      vote_average: 8.2
    }
  end

  # provider: :tvdb is load-bearing. RequestMediaLive.Index.build_request_attrs/3
  # only stores tvdb_id when the result carries it, and MediaRequests routes
  # approval by which id is present.
  defp series_search_result do
    %SearchResult{
      provider_id: to_string(@series_tvdb_id),
      provider: :tvdb,
      media_type: :tv_show,
      id: @series_tvdb_id,
      title: @series_title,
      name: @series_title,
      original_name: @series_title,
      first_air_date: "2008-01-20",
      overview: "A stub series used by the guest request tests.",
      poster_path: "/stub-series-poster.jpg",
      vote_average: 9.0
    }
  end

  defp movie_metadata do
    %MediaMetadata{
      provider_id: to_string(@movie_tmdb_id),
      provider: :metadata_relay,
      media_type: :movie,
      id: @movie_tmdb_id,
      title: @movie_title,
      original_title: @movie_title,
      year: 1999,
      release_date: "1999-03-30",
      overview: "A stub movie used by the guest request tests.",
      runtime: 136,
      genres: ["Action"],
      poster_path: "/stub-movie-poster.jpg",
      imdb_id: "tt0000550",
      original_language: "en",
      vote_average: 8.2
    }
  end

  # seasons must be non-empty for Media.create_media_item/2 to fetch episodes
  # (lib/mydia/media.ex:1354 reads `metadata.seasons || []`).
  defp series_metadata do
    %MediaMetadata{
      provider_id: to_string(@series_tvdb_id),
      provider: :tvdb,
      media_type: :tv_show,
      id: @series_tvdb_id,
      title: @series_title,
      original_title: @series_title,
      year: 2008,
      first_air_date: "2008-01-20",
      overview: "A stub series used by the guest request tests.",
      genres: ["Drama"],
      poster_path: "/stub-series-poster.jpg",
      imdb_id: "tt0000081",
      original_language: "en",
      number_of_seasons: 1,
      number_of_episodes: 2,
      vote_average: 9.0,
      seasons: [
        %SeasonInfo{
          season_number: 1,
          name: "Season 1",
          overview: "Stub season.",
          episode_count: 2
        }
      ]
    }
  end
end
