defmodule Mydia.Media.CategoryUpdateTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Events
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  describe "update_category/3 audit" do
    test "persists category and records old/new in history" do
      item = media_item_fixture(%{type: "movie"})
      assert item.category == "movie"

      assert {:ok, updated} =
               Media.update_category(item, :anime_movie,
                 reason: "Category updated",
                 actor_type: :user,
                 actor_id: "user-1"
               )

      assert updated.category == "anime_movie"
      assert Repo.get!(MediaItem, item.id).category == "anime_movie"

      [event] =
        Events.list_events(
          type: "media_item.updated",
          resource_type: "media_item",
          resource_id: item.id
        )

      assert event.metadata["reason"] == "Category updated"
      assert event.metadata["changes"]["category"] == %{"old" => "movie", "new" => "anime_movie"}
    end

    test "persists category_override when override: true" do
      item = media_item_fixture(%{type: "movie"})

      assert {:ok, updated} =
               Media.update_category(item, :cartoon_movie,
                 override: true,
                 reason: "Category updated",
                 actor_type: :user,
                 actor_id: "user-1"
               )

      assert updated.category_override == true
      assert Repo.get!(MediaItem, item.id).category_override == true

      [event] =
        Events.list_events(
          type: "media_item.updated",
          resource_type: "media_item",
          resource_id: item.id
        )

      assert event.metadata["changes"]["category_override"] == %{"old" => false, "new" => true}
    end

    test "does not emit media_item.updated when nothing changed" do
      item = media_item_fixture(%{type: "movie"})

      assert {:ok, _} =
               Media.update_category(item, :movie,
                 override: false,
                 reason: "Category updated",
                 actor_type: :user,
                 actor_id: "user-1"
               )

      assert Events.list_events(
               type: "media_item.updated",
               resource_type: "media_item",
               resource_id: item.id
             ) == []
    end

    test "clearing override persists category_override false" do
      item = media_item_fixture(%{type: "movie"})
      {:ok, item} = Media.update_category(item, :cartoon_movie, override: true)

      assert {:ok, updated} =
               Media.update_category(item, :movie,
                 override: false,
                 reason: "Category reset to auto-detected",
                 actor_type: :user,
                 actor_id: "user-1"
               )

      assert updated.category_override == false
      assert Repo.get!(MediaItem, item.id).category_override == false
    end

    test "update_media_item/3 cannot change category (boundary)" do
      item = media_item_fixture(%{type: "movie"})

      assert {:ok, updated} =
               Media.update_media_item(item, %{category: "anime_movie", category_override: true})

      assert updated.category == "movie"
      assert Repo.get!(MediaItem, item.id).category == "movie"
    end
  end
end
