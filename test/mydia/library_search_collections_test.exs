defmodule Mydia.LibrarySearchCollectionsTest do
  use Mydia.DataCase

  import Mydia.AccountsFixtures
  import Mydia.CollectionsFixtures
  import Mydia.MediaFixtures

  alias Mydia.LibrarySearch
  alias Mydia.LibrarySearch.Result

  setup do
    # `other_user` is an admin because `Collections.create_collection/2` returns
    # `{:error, :unauthorized}` when a non-admin tries to create a "shared"
    # collection, which would blow up the shared-visibility test below.
    %{user: user_fixture(), other_user: admin_user_fixture()}
  end

  defp collection_section(results) do
    Enum.find(results.sections, &(&1.type == :collection))
  end

  defp names(results) do
    case collection_section(results) do
      nil -> []
      section -> Enum.map(section.results, & &1.title)
    end
  end

  describe "matching" do
    test "matches a collection by name", %{user: user} do
      collection_fixture(%{user: user, name: "Alien Anthology", poster_path: "/collection.jpg"})

      {:ok, results} = LibrarySearch.search(user, "alien")

      assert [
               %Result{
                 type: :collection,
                 title: "Alien Anthology",
                 poster_path: "/collection.jpg",
                 year: nil,
                 season_number: nil,
                 episode_number: nil,
                 parent_id: nil
               }
             ] = collection_section(results).results
    end

    test "falls back to a member's poster when poster_path is unset", %{user: user} do
      collection = collection_fixture(%{user: user, name: "Alien Anthology"})

      collection_item_fixture(%{
        collection: collection,
        media_item: media_item_fixture(%{metadata: %{poster_path: "/member.jpg"}})
      })

      {:ok, results} = LibrarySearch.search(user, "alien")

      assert [%Result{poster_path: "/member.jpg"}] = collection_section(results).results
    end

    test "has no poster when poster_path is unset and the collection is empty", %{user: user} do
      collection_fixture(%{user: user, name: "Alien Anthology"})

      {:ok, results} = LibrarySearch.search(user, "alien")

      assert [%Result{poster_path: nil}] = collection_section(results).results
    end

    test "reports the item count as the subtitle", %{user: user} do
      collection = collection_fixture(%{user: user, name: "Alien Anthology"})
      collection_item_fixture(%{collection: collection, media_item: media_item_fixture()})
      collection_item_fixture(%{collection: collection, media_item: media_item_fixture()})

      {:ok, results} = LibrarySearch.search(user, "alien")

      assert [%Result{subtitle: "2 items"}] = collection_section(results).results
    end

    test "uses the singular form for a single item", %{user: user} do
      collection = collection_fixture(%{user: user, name: "Alien Anthology"})
      collection_item_fixture(%{collection: collection, media_item: media_item_fixture()})

      {:ok, results} = LibrarySearch.search(user, "alien")

      assert [%Result{subtitle: "1 item"}] = collection_section(results).results
    end

    test "ranks collection names on the same four tiers", %{user: user} do
      for name <- ["zzz Prebacked", "yyy The Back Shelf", "Backdrops", "back"] do
        collection_fixture(%{user: user, name: name})
      end

      {:ok, results} = LibrarySearch.search(user, "back")

      assert names(results) == ["back", "Backdrops", "yyy The Back Shelf", "zzz Prebacked"]

      assert Enum.map(collection_section(results).results, & &1.score) == [
               100.0,
               75.0,
               50.0,
               25.0
             ]
    end

    test "omits the collection section when nothing matches", %{user: user} do
      media_item_fixture(%{type: "movie", title: "Alien"})

      {:ok, results} = LibrarySearch.search(user, "alien")

      assert collection_section(results) == nil
    end
  end

  describe "authorization" do
    test "the user's own private collection appears", %{user: user} do
      collection_fixture(%{user: user, name: "Alien Anthology", visibility: "private"})

      {:ok, results} = LibrarySearch.search(user, "alien")

      assert names(results) == ["Alien Anthology"]
    end

    test "another user's private collection never appears", %{user: user, other_user: other} do
      collection_fixture(%{user: other, name: "Alien Anthology", visibility: "private"})

      {:ok, results} = LibrarySearch.search(user, "alien")

      assert names(results) == []
    end

    test "another user's shared collection does appear", %{user: user, other_user: other} do
      collection_fixture(%{user: other, name: "Alien Anthology", visibility: "shared"})

      {:ok, results} = LibrarySearch.search(user, "alien")

      assert names(results) == ["Alien Anthology"]
    end

    test "the total count excludes another user's private collections", %{
      user: user,
      other_user: other
    } do
      collection_fixture(%{user: user, name: "Alien Anthology", visibility: "private"})
      collection_fixture(%{user: other, name: "Alien Extras", visibility: "private"})

      {:ok, results} = LibrarySearch.search(user, "alien")

      assert collection_section(results).total_count == 1
    end
  end
end
