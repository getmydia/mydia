defmodule Mydia.CollectionsTest do
  use Mydia.DataCase

  alias Mydia.Accounts.Scope
  alias Mydia.Collections
  alias Mydia.Collections.{Collection, CollectionItem}

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.CollectionsFixtures

  describe "collections" do
    test "list_collections/2 returns all user's collections and shared collections" do
      user = user_fixture()
      other_user = user_fixture()
      admin = admin_user_fixture()

      # User's own collection
      own_collection = collection_fixture(%{user: user, name: "My Collection"})

      # Another user's private collection (should not appear)
      _private_collection = collection_fixture(%{user: other_user, name: "Other Private"})

      # Admin's shared collection (should appear)
      {:ok, shared_collection} =
        Collections.create_collection(admin, %{
          name: "Shared Collection",
          type: "manual",
          visibility: "shared"
        })

      collections = Collections.list_collections(user)
      collection_ids = Enum.map(collections, & &1.id)

      assert own_collection.id in collection_ids
      assert shared_collection.id in collection_ids
      assert length(collections) == 2
    end

    test "list_collections/2 with include_shared: false excludes shared collections" do
      user = user_fixture()
      admin = admin_user_fixture()

      own_collection = collection_fixture(%{user: user})

      {:ok, _shared_collection} =
        Collections.create_collection(admin, %{
          name: "Shared",
          type: "manual",
          visibility: "shared"
        })

      collections = Collections.list_collections(user, include_shared: false)

      assert length(collections) == 1
      assert hd(collections).id == own_collection.id
    end

    test "list_collections/2 filters by type" do
      user = user_fixture()

      _manual = collection_fixture(%{user: user, type: "manual"})
      smart = smart_collection_fixture(%{user: user})

      collections = Collections.list_collections(user, type: "smart")

      assert length(collections) == 1
      assert hd(collections).id == smart.id
    end

    test "get_collection!/3 returns the collection if accessible" do
      user = user_fixture()
      collection = collection_fixture(%{user: user})

      assert Collections.get_collection!(user, collection.id).id == collection.id
    end

    test "get_collection!/3 raises for inaccessible collection" do
      user = user_fixture()
      other_user = user_fixture()
      collection = collection_fixture(%{user: other_user, visibility: "private"})

      assert_raise Ecto.NoResultsError, fn ->
        Collections.get_collection!(user, collection.id)
      end
    end

    test "create_collection/2 creates a manual collection" do
      user = user_fixture()

      attrs = %{name: "My Movies", type: "manual", visibility: "private"}

      assert {:ok, %Collection{} = collection} = Collections.create_collection(user, attrs)
      assert collection.name == "My Movies"
      assert collection.type == "manual"
      assert collection.visibility == "private"
      assert collection.user_id == user.id
    end

    test "create_collection/2 creates a smart collection with rules" do
      user = user_fixture()

      rules = %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "year", "operator" => "gte", "value" => 2020}
        ]
      }

      attrs = %{
        name: "Recent Movies",
        type: "smart",
        visibility: "private",
        smart_rules: Jason.encode!(rules)
      }

      assert {:ok, %Collection{} = collection} = Collections.create_collection(user, attrs)
      assert collection.type == "smart"
      assert collection.smart_rules != nil
    end

    test "create_collection/2 prevents non-admin from creating shared collection" do
      user = user_fixture()

      attrs = %{name: "Shared", type: "manual", visibility: "shared"}

      assert {:error, :unauthorized} = Collections.create_collection(user, attrs)
    end

    test "create_collection/2 allows admin to create shared collection" do
      admin = admin_user_fixture()

      attrs = %{name: "Shared", type: "manual", visibility: "shared"}

      assert {:ok, %Collection{} = collection} = Collections.create_collection(admin, attrs)
      assert collection.visibility == "shared"
    end

    test "update_collection/3 updates the collection" do
      user = user_fixture()
      collection = collection_fixture(%{user: user, name: "Original"})

      assert {:ok, %Collection{} = updated} =
               Collections.update_collection(user, collection, %{name: "Updated"})

      assert updated.name == "Updated"
    end

    test "update_collection/3 prevents updating another user's collection" do
      user = user_fixture()
      other_user = user_fixture()
      collection = collection_fixture(%{user: other_user})

      assert {:error, :unauthorized} =
               Collections.update_collection(user, collection, %{name: "Hacked"})
    end

    test "update_collection/3 prevents updating system collections" do
      user = user_fixture()
      {:ok, favorites} = Collections.get_or_create_favorites(user)

      assert {:error, :system_collection} =
               Collections.update_collection(user, favorites, %{name: "Renamed"})
    end

    test "delete_collection/2 deletes the collection" do
      user = user_fixture()
      collection = collection_fixture(%{user: user})

      assert {:ok, %Collection{}} = Collections.delete_collection(user, collection)

      assert Collections.get_collection(user, collection.id) == nil
    end

    test "delete_collection/2 prevents deleting another user's collection" do
      user = user_fixture()
      other_user = user_fixture()
      collection = collection_fixture(%{user: other_user})

      assert {:error, :unauthorized} = Collections.delete_collection(user, collection)
    end

    test "delete_collection/2 prevents deleting system collections" do
      user = user_fixture()
      {:ok, favorites} = Collections.get_or_create_favorites(user)

      assert {:error, :system_collection} = Collections.delete_collection(user, favorites)
    end
  end

  describe "favorites (system collection)" do
    test "get_or_create_favorites/1 creates favorites on first call" do
      user = user_fixture()

      assert {:ok, %Collection{} = favorites} = Collections.get_or_create_favorites(user)
      assert favorites.name == "Favorites"
      assert favorites.is_system == true
      assert favorites.type == "manual"
    end

    test "get_or_create_favorites/1 returns existing favorites on subsequent calls" do
      user = user_fixture()

      {:ok, first} = Collections.get_or_create_favorites(user)
      {:ok, second} = Collections.get_or_create_favorites(user)

      assert first.id == second.id
    end

    test "is_favorite?/2 returns false when item is not favorited" do
      user = user_fixture()
      media_item = media_item_fixture()

      refute Collections.is_favorite?(Scope.for_user(user), media_item.id)
    end

    test "toggle_favorite/2 adds and removes from favorites" do
      user = user_fixture()
      media_item = media_item_fixture()
      scope = Scope.for_user(user)

      # Add to favorites
      assert {:ok, :added} = Collections.toggle_favorite(user, media_item.id)
      assert Collections.is_favorite?(scope, media_item.id)

      # Remove from favorites
      assert {:ok, :removed} = Collections.toggle_favorite(user, media_item.id)
      refute Collections.is_favorite?(scope, media_item.id)
    end
  end

  describe "collection items" do
    test "add_item/2 adds item to manual collection" do
      user = user_fixture()
      collection = collection_fixture(%{user: user})
      media_item = media_item_fixture()

      assert {:ok, %CollectionItem{}} = Collections.add_item(collection, media_item.id)

      items = Collections.list_collection_items(Scope.unrestricted(), collection)
      assert length(items) == 1
      assert hd(items).id == media_item.id
    end

    test "add_item/2 returns error for smart collection" do
      user = user_fixture()
      collection = smart_collection_fixture(%{user: user})
      media_item = media_item_fixture()

      assert {:error, :smart_collection} = Collections.add_item(collection, media_item.id)
    end

    test "add_items/2 adds multiple items at once" do
      user = user_fixture()
      collection = collection_fixture(%{user: user})
      items = for _ <- 1..3, do: media_item_fixture()
      item_ids = Enum.map(items, & &1.id)

      assert {:ok, 3} = Collections.add_items(collection, item_ids)

      collection_items = Collections.list_collection_items(Scope.unrestricted(), collection)
      assert length(collection_items) == 3
    end

    test "remove_item/2 removes item from collection" do
      user = user_fixture()
      collection = collection_fixture(%{user: user})
      media_item = media_item_fixture()

      {:ok, _} = Collections.add_item(collection, media_item.id)
      assert {:ok, %CollectionItem{}} = Collections.remove_item(collection, media_item.id)

      items = Collections.list_collection_items(Scope.unrestricted(), collection)
      assert items == []
    end

    test "remove_item/2 returns error for non-existent item" do
      user = user_fixture()
      collection = collection_fixture(%{user: user})
      media_item = media_item_fixture()

      assert {:error, :not_found} = Collections.remove_item(collection, media_item.id)
    end

    test "reorder_items/2 reorders items in collection" do
      user = user_fixture()
      collection = collection_fixture(%{user: user})
      items = for _ <- 1..3, do: media_item_fixture()
      item_ids = Enum.map(items, & &1.id)

      {:ok, _} = Collections.add_items(collection, item_ids)

      # Reverse the order
      reversed_ids = Enum.reverse(item_ids)
      assert {:ok, :ok} = Collections.reorder_items(collection, reversed_ids)

      collection_items = Collections.list_collection_items(Scope.unrestricted(), collection)
      result_ids = Enum.map(collection_items, & &1.id)
      assert result_ids == reversed_ids
    end

    test "item_count/1 returns correct count for manual collection" do
      user = user_fixture()
      collection = collection_fixture(%{user: user})
      items = for _ <- 1..5, do: media_item_fixture()
      item_ids = Enum.map(items, & &1.id)

      {:ok, _} = Collections.add_items(collection, item_ids)

      assert Collections.item_count(collection) == 5
    end

    test "collections_for_item/2 returns collections containing the item" do
      user = user_fixture()
      collection1 = collection_fixture(%{user: user, name: "Collection 1"})
      collection2 = collection_fixture(%{user: user, name: "Collection 2"})
      _collection3 = collection_fixture(%{user: user, name: "Collection 3"})
      media_item = media_item_fixture()

      {:ok, _} = Collections.add_item(collection1, media_item.id)
      {:ok, _} = Collections.add_item(collection2, media_item.id)

      collections = Collections.collections_for_item(user, media_item.id)
      collection_ids = Enum.map(collections, & &1.id)

      assert length(collections) == 2
      assert collection1.id in collection_ids
      assert collection2.id in collection_ids
    end
  end

  describe "smart collections" do
    test "list_collection_items/2 returns items matching smart rules" do
      user = user_fixture()

      # Create media items
      movie = media_item_fixture(%{type: "movie", title: "Test Movie"})
      _tv_show = media_item_fixture(%{type: "tv_show", title: "Test Show"})

      # Create smart collection for movies only
      collection =
        smart_collection_fixture(%{
          user: user,
          rules: %{
            "match_type" => "all",
            "conditions" => [
              %{"field" => "type", "operator" => "eq", "value" => "movie"}
            ]
          }
        })

      items = Collections.list_collection_items(Scope.unrestricted(), collection)

      assert length(items) == 1
      assert hd(items).id == movie.id
    end

    test "list_collection_items/2 applies year filters" do
      user = user_fixture()

      recent = media_item_fixture(%{type: "movie", year: 2023})
      _old = media_item_fixture(%{type: "movie", year: 2010})

      collection =
        smart_collection_fixture(%{
          user: user,
          rules: %{
            "match_type" => "all",
            "conditions" => [
              %{"field" => "year", "operator" => "gte", "value" => 2020}
            ]
          }
        })

      items = Collections.list_collection_items(Scope.unrestricted(), collection)

      assert length(items) == 1
      assert hd(items).id == recent.id
    end

    test "item_count/1 returns correct count for smart collection" do
      user = user_fixture()

      for _ <- 1..3, do: media_item_fixture(%{type: "movie"})
      for _ <- 1..2, do: media_item_fixture(%{type: "tv_show"})

      collection =
        smart_collection_fixture(%{
          user: user,
          rules: %{
            "match_type" => "all",
            "conditions" => [
              %{"field" => "type", "operator" => "eq", "value" => "movie"}
            ]
          }
        })

      assert Collections.item_count(collection) == 3
    end
  end
end
