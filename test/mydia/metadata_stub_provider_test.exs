defmodule Mydia.MetadataStubProviderTest do
  # async: false because setup_metadata_stub mutates the global Provider.Registry Agent.
  use Mydia.DataCase, async: false

  import Mydia.MetadataStub

  alias Mydia.Metadata
  alias Mydia.MetadataStubProvider

  setup :setup_metadata_stub

  describe "self-consistency" do
    test "a movie id returned by search/3 is resolvable by fetch_by_id/3" do
      config = Metadata.default_relay_config()

      {:ok, [result]} = Metadata.search(config, "stub", media_type: :movie)

      assert result.id == MetadataStubProvider.movie_tmdb_id()
      assert result.media_type == :movie

      {:ok, metadata} =
        Metadata.fetch_by_id(config, result.provider_id, media_type: :movie, provider: :tmdb)

      assert metadata.title == MetadataStubProvider.movie_title()
    end

    test "a series id returned by search/3 is resolvable via the tvdb branch" do
      config = Metadata.default_relay_config()

      {:ok, [result]} = Metadata.search(config, "stub", media_type: :tv_show)

      assert result.id == MetadataStubProvider.series_tvdb_id()

      assert result.provider == :tvdb,
             "build_request_attrs/3 only stores tvdb_id when provider is :tvdb"

      {:ok, metadata} =
        Metadata.fetch_by_id(config, result.provider_id, media_type: :tv_show, provider: :tvdb)

      assert metadata.title == MetadataStubProvider.series_title()
      assert [season1, season2] = metadata.seasons
      assert season1.season_number == 1
      assert season2.season_number == 2
    end

    test "the reserved missing id always fails the fetch" do
      config = Metadata.default_relay_config()

      assert {:error, %Metadata.Provider.Error{type: :not_found}} =
               Metadata.fetch_by_id(config, to_string(MetadataStubProvider.missing_id()),
                 media_type: :movie,
                 provider: :tmdb
               )
    end

    test "fetch_season/4 returns episodes for the stub series" do
      config = Metadata.default_relay_config()

      {:ok, season} =
        Metadata.fetch_season(config, to_string(MetadataStubProvider.series_tvdb_id()), 1, [])

      assert season.season_number == 1
      assert length(season.episodes) == 2
    end
  end

  describe "registry restoration" do
    test "the real relay provider is registered again after the test exits" do
      # Inside this test the stub is active.
      assert {:ok, MetadataStubProvider} =
               Metadata.Provider.Registry.get_provider(:metadata_relay)
    end
  end
end
