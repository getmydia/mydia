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

    test "a manual collection with a pinned_position is rejected" do
      changeset =
        Collection.changeset(%Collection{}, %{
          name: "Watchlist",
          type: "manual",
          visibility: "private",
          pinned_position: 0
        })

      refute changeset.valid?

      assert %{pinned_position: ["only smart collections can be pinned"]} =
               errors_on(changeset)
    end

    test "an unpinned manual collection still validates" do
      changeset =
        Collection.changeset(%Collection{}, %{
          name: "Watchlist",
          type: "manual",
          visibility: "private"
        })

      assert changeset.valid?
    end

    test "a pinned smart collection still validates" do
      changeset =
        Collection.changeset(%Collection{}, %{
          name: "Anime",
          type: "smart",
          visibility: "private",
          smart_rules:
            ~s({"conditions":[{"field":"category","operator":"in","value":["anime_movie"]}]}),
          pinned_position: 0
        })

      assert changeset.valid?
    end
  end

  describe "list_pinned_sections/1" do
    test "returns only the user's pinned collections, in position order" do
      user = user_fixture()

      {:ok, second} = pinned(user, "Cartoons", 1, ["cartoon_movie"])
      {:ok, first} = pinned(user, "Anime", 0, ["anime_movie"])
      {:ok, _unpinned} = Collections.create_collection(user, plain_attrs("Not Pinned"))

      assert [^first, ^second] = Collections.list_pinned_sections(user)
    end

    test "does not return another user's pinned collection, even when shared" do
      owner = admin_user_fixture()
      other = user_fixture()

      {:ok, collection} = pinned(owner, "Anime", 0, ["anime_movie"])
      {:ok, _} = Collections.update_collection(owner, collection, %{visibility: "shared"})

      assert Collections.list_pinned_sections(other) == []
    end
  end

  describe "claimed_categories/1" do
    test "returns the categories of an exclusive pure-category section" do
      user = user_fixture()
      {:ok, _} = pinned(user, "Anime", 0, ["anime_movie", "anime_series"], exclusive: true)

      assert Enum.sort(Collections.claimed_categories(user)) ==
               ["anime_movie", "anime_series"]
    end

    test "returns nothing when the section is not exclusive" do
      user = user_fixture()
      {:ok, _} = pinned(user, "Anime", 0, ["anime_movie"], exclusive: false)

      assert Collections.claimed_categories(user) == []
    end

    test "returns nothing when the rules are not a single category condition" do
      user = user_fixture()

      rules =
        ~s({"conditions":[{"field":"category","operator":"in","value":["anime_movie"]},) <>
          ~s({"field":"year","operator":"gte","value":2020}]})

      {:ok, _} =
        Collections.create_collection(user, %{
          name: "Recent Anime",
          type: "smart",
          visibility: "private",
          smart_rules: rules,
          pinned_position: 0,
          exclusive: true
        })

      assert Collections.claimed_categories(user) == []
    end

    test "returns nothing and does not raise when the rules are unparseable" do
      user = user_fixture()
      {:ok, collection} = pinned(user, "Anime", 0, ["anime_movie"], exclusive: true)

      # Bypass the changeset to simulate rules corrupted outside the app.
      collection
      |> Ecto.Changeset.change(%{smart_rules: "{not json"})
      |> Mydia.Repo.update!()

      assert Collections.claimed_categories(user) == []
    end

    test "ignores category values that are not real categories" do
      user = user_fixture()
      {:ok, _} = pinned(user, "Bogus", 0, ["anime_movie", "not_a_category"], exclusive: true)

      assert Collections.claimed_categories(user) == ["anime_movie"]
    end
  end

  describe "pin_section/3 and unpin_section/2" do
    test "pinning appends to the end of the existing sections" do
      user = user_fixture()
      {:ok, _} = pinned(user, "Anime", 0, ["anime_movie"])

      {:ok, collection} =
        Collections.create_collection(user, smart_attrs("Cartoons", ["cartoon_movie"]))

      {:ok, pinned_collection} =
        Collections.pin_section(user, collection, sidebar_icon: "hero-face-smile")

      assert pinned_collection.pinned_position == 1
      assert pinned_collection.sidebar_icon == "hero-face-smile"
    end

    test "unpinning clears the position and exclusivity" do
      user = user_fixture()
      {:ok, collection} = pinned(user, "Anime", 0, ["anime_movie"], exclusive: true)

      {:ok, unpinned} = Collections.unpin_section(user, collection)

      assert is_nil(unpinned.pinned_position)
      assert unpinned.exclusive == false
      assert Collections.claimed_categories(user) == []
    end

    test "pinning a manual collection is refused" do
      user = user_fixture()
      {:ok, collection} = Collections.create_collection(user, plain_attrs("Watchlist"))

      assert Collections.pin_section(user, collection) == {:error, :not_smart}
      assert Collections.list_pinned_sections(user) == []
    end

    test "re-pinning with no opts keeps a previously customized icon" do
      user = user_fixture()

      {:ok, collection} =
        Collections.create_collection(user, smart_attrs("Anime", ["anime_movie"]))

      {:ok, pinned_collection} =
        Collections.pin_section(user, collection, sidebar_icon: "hero-face-smile")

      # Simulate customizing the icon via the section settings gear, which
      # goes through update_collection/3, not pin_section/3.
      {:ok, customized} =
        Collections.update_collection(user, pinned_collection, %{sidebar_icon: "hero-star"})

      {:ok, unpinned} = Collections.unpin_section(user, customized)

      {:ok, repinned} = Collections.pin_section(user, unpinned)

      assert repinned.sidebar_icon == "hero-star"
    end

    test "re-pinning with an explicit sidebar_icon still overwrites it" do
      user = user_fixture()

      {:ok, collection} =
        Collections.create_collection(user, smart_attrs("Anime", ["anime_movie"]))

      {:ok, pinned_collection} =
        Collections.pin_section(user, collection, sidebar_icon: "hero-star")

      {:ok, unpinned} = Collections.unpin_section(user, pinned_collection)

      {:ok, repinned} =
        Collections.pin_section(user, unpinned, sidebar_icon: "hero-face-smile")

      assert repinned.sidebar_icon == "hero-face-smile"
    end
  end

  describe "exclusive_eligible?/1" do
    test "true for a single category-in condition" do
      user = user_fixture()
      {:ok, collection} = pinned(user, "Anime", 0, ["anime_movie"])

      assert Collections.exclusive_eligible?(collection)
    end

    test "false for a manual collection" do
      user = user_fixture()
      {:ok, collection} = Collections.create_collection(user, plain_attrs("Manual"))

      refute Collections.exclusive_eligible?(collection)
    end
  end

  defp plain_attrs(name) do
    %{name: name, type: "manual", visibility: "private"}
  end

  defp smart_attrs(name, categories) do
    %{
      name: name,
      type: "smart",
      visibility: "private",
      smart_rules:
        Jason.encode!(%{
          "conditions" => [
            %{"field" => "category", "operator" => "in", "value" => categories}
          ]
        })
    }
  end

  defp pinned(user, name, position, categories, opts \\ []) do
    attrs =
      name
      |> smart_attrs(categories)
      |> Map.merge(%{
        pinned_position: position,
        exclusive: Keyword.get(opts, :exclusive, false)
      })

    Collections.create_collection(user, attrs)
  end

  describe "SectionPresets" do
    alias Mydia.Collections.SectionPresets

    test "every preset produces a collection that validates" do
      user = user_fixture()

      for preset <- SectionPresets.all() do
        assert {:ok, collection} =
                 Collections.create_collection(user, %{
                   name: preset.name,
                   type: "smart",
                   visibility: "private",
                   smart_rules: Jason.encode!(preset.rules),
                   sidebar_icon: preset.icon
                 }),
               "preset #{preset.key} did not create"

        assert {:ok, _} = Collections.validate_smart_rules(collection.smart_rules)
      end
    end

    test "every preset icon is on the allowlist" do
      for preset <- SectionPresets.all() do
        assert preset.icon in Collection.valid_sidebar_icons()
      end
    end

    test "the anime preset claims both anime categories and is exclusive" do
      preset = SectionPresets.get("anime")

      assert preset.exclusive
      assert %{"conditions" => [%{"field" => "category", "value" => values}]} = preset.rules
      assert Enum.sort(values) == ["anime_movie", "anime_series"]
    end

    test "get/1 returns nil for an unknown key" do
      assert is_nil(SectionPresets.get("nope"))
    end
  end

  describe "pinned_categories/1" do
    test "returns categories from every pinned section, exclusive or not" do
      user = user_fixture()

      {:ok, _exclusive} =
        Collections.create_collection(user, %{
          name: "Anime",
          type: "smart",
          visibility: "private",
          smart_rules:
            Jason.encode!(%{
              "conditions" => [
                %{"field" => "category", "operator" => "in", "value" => ["anime_series"]}
              ]
            }),
          pinned_position: 0,
          exclusive: true
        })

      {:ok, _plain} =
        Collections.create_collection(user, %{
          name: "Toons",
          type: "smart",
          visibility: "private",
          smart_rules:
            Jason.encode!(%{
              "conditions" => [
                %{"field" => "category", "operator" => "in", "value" => ["cartoon_series"]}
              ]
            }),
          pinned_position: 1,
          exclusive: false
        })

      sections = Collections.list_pinned_sections(user)

      assert Enum.sort(Collections.pinned_categories(sections)) ==
               ["anime_series", "cartoon_series"]

      assert Collections.claimed_categories(sections) == ["anime_series"]
    end
  end

  describe "section presets" do
    test "the anime preset uses an icon with no AI connotation" do
      preset = Mydia.Collections.SectionPresets.get("anime")

      assert preset.icon == "hero-bolt"
      assert preset.icon in Collection.valid_sidebar_icons()
    end

    test "every preset icon is allowlisted" do
      for preset <- Mydia.Collections.SectionPresets.all() do
        assert preset.icon in Collection.valid_sidebar_icons(),
               "#{preset.key} uses #{preset.icon}, which is not allowlisted"
      end
    end
  end
end
