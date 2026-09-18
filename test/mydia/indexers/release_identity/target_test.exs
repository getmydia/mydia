defmodule Mydia.Indexers.ReleaseIdentity.TargetTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.ReleaseIdentity.Target
  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Structs.MediaMetadata

  describe "from_media_item/1" do
    test "keys the title, the original title and the alternative titles" do
      item = %MediaItem{
        type: "movie",
        title: "The Lantern and Ash",
        year: 2031,
        original_title: "La Lanterne et la Cendre",
        metadata: %MediaMetadata{
          provider_id: "1",
          provider: :tmdb,
          media_type: :movie,
          alternative_titles: ["Starfall: The Lantern and Ash"]
        }
      }

      target = Target.from_media_item(item)

      assert target.type == :movie
      assert target.year == 2031
      assert target.keys == ["lanternash", "lalanterneetlacendre", "starfalllanternash"]
    end

    test "drops a trailing year from a show title" do
      target = Target.from_media_item(%MediaItem{type: "tv_show", title: "Dark Lantern (2024)"})

      assert target.type == :tv_show
      assert target.keys == ["darklantern"]
    end

    test "keeps a country suffix" do
      target = Target.from_media_item(%MediaItem{type: "tv_show", title: "The Ledger (US)"})

      assert target.keys == ["ledgerus"]
    end

    test "drops keys that are empty or repeated" do
      item = %MediaItem{
        type: "movie",
        title: "Glass Harbor",
        metadata: %MediaMetadata{
          provider_id: "1",
          provider: :tmdb,
          media_type: :movie,
          alternative_titles: ["Glass-Harbor", "The"]
        }
      }

      assert Target.from_media_item(item).keys == ["glassharbor"]
    end
  end
end
