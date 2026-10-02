defmodule Mydia.Plugins.ShelvesTest do
  # async: false: the plugin registry is app-wide.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.ShelfHelpers

  alias Mydia.Media.ProviderKey
  alias Mydia.Plugins.Shelf
  alias Mydia.Plugins.ShelfDismissal
  alias Mydia.Plugins.ShelfItem
  alias Mydia.Plugins.Shelves
  alias Mydia.Plugins.Shelves.Declared
  alias Mydia.Plugins.Shelves.View

  @now ~U[2026-10-01 12:00:00.000000Z]

  describe "declared/1" do
    test "lists enabled, granted plugins' shelves for a placement" do
      register_shelf_plugin!()

      assert [
               %Declared{
                 slug: "shelf-test",
                 key: "picks",
                 title: "Picked for you",
                 placement: "home",
                 scope: "user",
                 ttl_seconds: 86_400,
                 refresh_on: ["playback.finished"]
               }
             ] = Shelves.declared(:home)

      assert %Declared{key: "picks"} = Shelves.get_declared("shelf-test", "picks")
      assert Shelves.get_declared("shelf-test", "nope") == nil
    end

    test "skips a disabled plugin and one without the grant" do
      register_shelf_plugin!(slug: "off", enabled: false)
      register_shelf_plugin!(slug: "ungranted", granted: %{})

      assert Shelves.declared(:home) == []
    end
  end

  describe "list_for/3" do
    test "creates the user's row on first sight and reads it as stale" do
      register_shelf_plugin!()
      user = user_fixture()

      assert [%View{shelf: %Shelf{} = shelf, items: [], stale?: true}] =
               Shelves.list_for(user, :home, @now)

      assert shelf.user_id == user.id
      assert [%View{shelf: %Shelf{id: id}}] = Shelves.list_for(user, :home, @now)
      assert id == shelf.id
    end

    test "returns stored items in order and a fresh shelf as not stale" do
      register_shelf_plugin!()
      user = user_fixture()
      shelf = shelf_fixture(user, filled_at: @now, stale_at: DateTime.add(@now, 3600))
      shelf_item_fixture(shelf, %{position: 1, provider_id: 2, title: "Glass Meridian"})
      shelf_item_fixture(shelf, %{position: 0, provider_id: 1, title: "Ember Tide"})

      assert [%View{items: items, stale?: false}] = Shelves.list_for(user, :home, @now)
      assert Enum.map(items, & &1.title) == ["Ember Tide", "Glass Meridian"]
    end

    test "never returns another user's items" do
      register_shelf_plugin!()
      shelf_item_fixture(shelf_fixture(user_fixture()))

      assert [%View{items: []}] = Shelves.list_for(user_fixture(), :home, @now)
    end

    test "is empty when nothing declares a shelf" do
      assert Shelves.list_for(user_fixture(), :home, @now) == []
    end
  end

  describe "stale?/2" do
    test "never filled is stale; otherwise stale from stale_at onward" do
      assert Shelves.stale?(%Shelf{stale_at: nil}, @now)
      assert Shelves.stale?(%Shelf{stale_at: @now}, @now)
      assert Shelves.stale?(%Shelf{stale_at: DateTime.add(@now, -1)}, @now)
      refute Shelves.stale?(%Shelf{stale_at: DateTime.add(@now, 1)}, @now)
    end
  end

  describe "dismiss_item/2" do
    test "removes the card and remembers the title" do
      user = user_fixture()
      shelf = shelf_fixture(user)
      item = shelf_item_fixture(shelf, %{media_type: :tv_show, provider_id: 55})

      assert :ok = Shelves.dismiss_item(user, item.id)

      assert Repo.aggregate(ShelfItem, :count) == 0
      assert MapSet.member?(Shelves.dismissed_keys(shelf), ProviderKey.new(:tv_show, :tmdb, 55))
    end

    test "dismissing the same title twice is not an error" do
      user = user_fixture()
      shelf = shelf_fixture(user)

      assert :ok = Shelves.dismiss_item(user, shelf_item_fixture(shelf).id)
      assert :ok = Shelves.dismiss_item(user, shelf_item_fixture(shelf).id)
      assert Repo.aggregate(ShelfDismissal, :count) == 1
    end

    test "refuses another user's item and an unknown id" do
      item = shelf_item_fixture(shelf_fixture(user_fixture()))

      assert {:error, :not_found} = Shelves.dismiss_item(user_fixture(), item.id)
      assert {:error, :not_found} = Shelves.dismiss_item(user_fixture(), Ecto.UUID.generate())
      assert {:error, :not_found} = Shelves.dismiss_item(user_fixture(), "not-a-uuid")
      assert Repo.aggregate(ShelfItem, :count) == 1
    end
  end

  describe "purge/1" do
    test "deletes a plugin's shelves, items and dismissals and nobody else's" do
      user = user_fixture()
      mine = shelf_fixture(user)
      Shelves.dismiss_item(user, shelf_item_fixture(mine).id)
      shelf_item_fixture(mine, %{provider_id: 2})
      other = shelf_fixture(user, slug: "other-plugin")

      assert :ok = Shelves.purge("shelf-test")

      assert [%Shelf{id: id}] = Repo.all(Shelf)
      assert id == other.id
      assert Repo.aggregate(ShelfItem, :count) == 0
      assert Repo.aggregate(ShelfDismissal, :count) == 0
    end
  end
end
