defmodule Mydia.Library.ReleaseParser.TargetContextTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser.TargetContext
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Structs.MediaMetadata

  describe "from_media_item/1" do
    test "builds context from a fully-preloaded tv_show MediaItem" do
      item = %MediaItem{
        type: "tv_show",
        title: "Frieren",
        original_title: "葬送のフリーレン",
        year: 2023,
        tmdb_id: 209_867,
        tvdb_id: 424_285,
        imdb_id: "tt22248376",
        episodes: [
          %Episode{season_number: 1},
          %Episode{season_number: 1},
          %Episode{season_number: 2}
        ]
      }

      ctx = TargetContext.from_media_item(item)

      assert ctx.type == :tv_show
      assert ctx.title == "Frieren"
      assert ctx.year == 2023
      assert ctx.known_seasons == [1, 2]
      assert "葬送のフリーレン" in ctx.alt_titles
      assert ctx.external_ids == %{tmdb: 209_867, tvdb: 424_285, imdb: "tt22248376"}
    end

    test "movie type maps correctly" do
      item = %MediaItem{
        type: "movie",
        title: "Dune Part Two",
        year: 2024,
        episodes: []
      }

      ctx = TargetContext.from_media_item(item)
      assert ctx.type == :movie
      assert ctx.known_seasons == []
    end

    test "deduplicates and sorts known_seasons" do
      item = %MediaItem{
        type: "tv_show",
        title: "X",
        episodes: Enum.map([3, 1, 2, 1, 3, 2], fn n -> %Episode{season_number: n} end)
      }

      ctx = TargetContext.from_media_item(item)
      assert ctx.known_seasons == [1, 2, 3]
    end

    test "alt_titles excludes the primary title and any duplicates" do
      item = %MediaItem{
        type: "tv_show",
        title: "Frieren",
        original_title: "Frieren",
        episodes: [],
        metadata: %MediaMetadata{
          provider_id: "209867",
          provider: :tmdb,
          media_type: :tv_show,
          alternative_titles: ["Frieren", "葬送のフリーレン", "Sousou no Frieren"]
        }
      }

      ctx = TargetContext.from_media_item(item)
      assert "Frieren" not in ctx.alt_titles
      assert "葬送のフリーレン" in ctx.alt_titles
      assert "Sousou no Frieren" in ctx.alt_titles
    end

    test "tolerates nil metadata, original_title, year, and external IDs" do
      item = %MediaItem{
        type: "tv_show",
        title: "Show",
        episodes: []
      }

      ctx = TargetContext.from_media_item(item)
      assert ctx.title == "Show"
      assert ctx.year == nil
      assert ctx.alt_titles == []
      assert ctx.external_ids == %{tmdb: nil, tvdb: nil, imdb: nil}
    end

    test "raises ArgumentError when :episodes is not preloaded" do
      item = %MediaItem{
        type: "tv_show",
        title: "Show",
        episodes: %Ecto.Association.NotLoaded{}
      }

      assert_raise ArgumentError, ~r/:episodes to be preloaded/, fn ->
        TargetContext.from_media_item(item)
      end
    end

    test "raises ArgumentError on unknown type" do
      item = %MediaItem{
        type: "podcast",
        title: "Some Podcast",
        episodes: []
      }

      assert_raise ArgumentError, ~r/unknown media_item.type/, fn ->
        TargetContext.from_media_item(item)
      end
    end

    test "title defaults to empty string when nil" do
      item = %MediaItem{type: "movie", episodes: []}
      ctx = TargetContext.from_media_item(item)
      assert ctx.title == ""
    end
  end
end
