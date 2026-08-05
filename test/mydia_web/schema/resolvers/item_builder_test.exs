defmodule MydiaWeb.Schema.Resolvers.ItemBuilderTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias MydiaWeb.Schema.Resolvers.ItemBuilder

  describe "recently_added_item/2" do
    test "defaults added_at to the item's inserted_at" do
      item = media_item_fixture(%{type: "movie", title: "Heat", year: 1995})

      built = ItemBuilder.recently_added_item(item)

      assert built.id == item.id
      assert built.type == :movie
      assert built.title == "Heat"
      assert built.year == 1995
      assert built.added_at == item.inserted_at
      assert built.new_episode_count == nil
      assert built.latest_season_number == nil
      assert built.latest_episode_number == nil
    end

    test "overrides added_at when given" do
      item = media_item_fixture(%{type: "movie"})
      stamp = ~U[2026-01-02 03:04:05Z]

      built = ItemBuilder.recently_added_item(item, added_at: stamp)

      assert built.added_at == stamp
    end

    test "flattens the latest episode into season and episode numbers" do
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 4, episode_number: 2})

      built =
        ItemBuilder.recently_added_item(show,
          new_episode_count: 3,
          latest_episode: episode
        )

      assert built.new_episode_count == 3
      assert built.latest_season_number == 4
      assert built.latest_episode_number == 2
    end

    test "leaves episode numbers nil when there is no latest episode" do
      show = media_item_fixture(%{type: "tv_show"})

      built = ItemBuilder.recently_added_item(show, new_episode_count: 2)

      assert built.new_episode_count == 2
      assert built.latest_season_number == nil
      assert built.latest_episode_number == nil
    end
  end
end
