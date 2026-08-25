defmodule MydiaWeb.Live.Helpers.MediaRequestMetadataTest do
  @moduledoc """
  A TV request made while the instance is on TVDB metadata stores only a
  tvdb_id, so resolution has to route on whichever id the row carries.
  """

  # async: false: setup_metadata_stub swaps the global Provider.Registry.
  use Mydia.DataCase, async: false

  import Mydia.MetadataStub

  alias Mydia.Media.MediaRequest
  alias Mydia.Metadata.Structs.SearchResult
  alias Mydia.MetadataStubProvider
  alias MydiaWeb.Live.Helpers.MediaRequestHelpers

  setup :setup_metadata_stub

  describe "fetch_request_metadata/1" do
    test "resolves a movie by tmdb_id" do
      request = %MediaRequest{
        media_type: "movie",
        title: "Stub Movie",
        tmdb_id: MetadataStubProvider.movie_tmdb_id()
      }

      assert {:ok, metadata} = MediaRequestHelpers.fetch_request_metadata(request)
      assert metadata.title == MetadataStubProvider.movie_title()
      assert metadata.poster_path == "/stub-movie-poster.jpg"
    end

    test "resolves a series that only has a tvdb_id" do
      request = %MediaRequest{
        media_type: "tv_show",
        title: "Stub Series",
        tvdb_id: MetadataStubProvider.series_tvdb_id()
      }

      assert {:ok, metadata} = MediaRequestHelpers.fetch_request_metadata(request)
      assert metadata.title == MetadataStubProvider.series_title()
      assert metadata.poster_path == "/stub-series-poster.jpg"
    end

    test "returns :no_provider_id for an imdb-only request" do
      request = %MediaRequest{media_type: "movie", title: "Old One", imdb_id: "tt0137523"}

      assert {:error, :no_provider_id} = MediaRequestHelpers.fetch_request_metadata(request)
    end

    test "passes a provider failure through" do
      request = %MediaRequest{
        media_type: "movie",
        title: "Missing",
        tmdb_id: MetadataStubProvider.missing_id()
      }

      assert {:error, _reason} = MediaRequestHelpers.fetch_request_metadata(request)
    end
  end

  describe "to_search_result/1" do
    test "builds the item shape the detail popup reads" do
      request = %MediaRequest{
        media_type: "movie",
        title: "Stub Movie",
        year: 1999,
        tmdb_id: 550,
        poster_path: "/stub-movie-poster.jpg"
      }

      assert %SearchResult{} = item = MediaRequestHelpers.to_search_result(request)
      assert item.provider_id == "550"
      assert item.provider == :tmdb
      assert item.media_type == :movie
      assert item.title == "Stub Movie"
      assert item.year == 1999
      assert item.poster_path == "/stub-movie-poster.jpg"
    end

    test "tags a tvdb-only series with the tvdb provider" do
      request = %MediaRequest{media_type: "tv_show", title: "Stub Series", tvdb_id: 81_189}

      assert %SearchResult{provider: :tvdb, provider_id: "81189", media_type: :tv_show} =
               MediaRequestHelpers.to_search_result(request)
    end

    test "returns nil when there is nothing to resolve" do
      assert is_nil(
               MediaRequestHelpers.to_search_result(%MediaRequest{
                 media_type: "movie",
                 imdb_id: "tt0137523"
               })
             )
    end
  end
end
