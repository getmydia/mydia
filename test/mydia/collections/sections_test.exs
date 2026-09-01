defmodule Mydia.Collections.SectionsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Collections
  alias Mydia.Collections.Collection

  import Mydia.AccountsFixtures

  describe "sidebar section fields" do
    test "changeset accepts a pinned position, an allowlisted icon and exclusive" do
      user = user_fixture()

      {:ok, collection} =
        Collections.create_collection(user, %{
          name: "Anime",
          type: "smart",
          visibility: "private",
          smart_rules:
            ~s({"conditions":[{"field":"category","operator":"in","value":["anime_movie","anime_series"]}]}),
          pinned_position: 0,
          sidebar_icon: "hero-sparkles",
          exclusive: true
        })

      assert collection.pinned_position == 0
      assert collection.sidebar_icon == "hero-sparkles"
      assert collection.exclusive == true
    end

    test "defaults leave a collection unpinned and non-exclusive" do
      user = user_fixture()

      {:ok, collection} =
        Collections.create_collection(user, %{
          name: "Plain List",
          type: "manual",
          visibility: "private"
        })

      assert is_nil(collection.pinned_position)
      assert is_nil(collection.sidebar_icon)
      assert collection.exclusive == false
    end

    test "an icon outside the allowlist is rejected" do
      changeset =
        Collection.changeset(%Collection{}, %{
          name: "Bad Icon",
          type: "manual",
          visibility: "private",
          sidebar_icon: "hero-not-a-real-icon"
        })

      refute changeset.valid?
      assert %{sidebar_icon: ["is not a supported icon"]} = errors_on(changeset)
    end

    test "valid_sidebar_icons are all hero-prefixed" do
      assert Enum.all?(Collection.valid_sidebar_icons(), &String.starts_with?(&1, "hero-"))
      assert "hero-sparkles" in Collection.valid_sidebar_icons()
    end
  end
end
