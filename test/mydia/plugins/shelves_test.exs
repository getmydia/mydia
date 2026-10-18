defmodule Mydia.Plugins.ShelvesTest do
  # async: false: the plugin registry is app-wide.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.ShelfHelpers

  alias Mydia.Media.ProviderKey
  alias Mydia.Plugins.Shelf
  alias Mydia.Plugins.ShelfFeedback
  alias Mydia.Plugins.ShelfItem
  alias Mydia.Plugins.Shelves
  alias Mydia.Plugins.Shelves.Declared
  alias Mydia.Plugins.Shelves.View

  @now ~U[2026-10-01 12:00:00.000000Z]

  # Schemaless inserts skip the schema's type dumping: Postgres wants 16 raw
  # bytes for a binary_id column, SQLite stores the text form.
  defp raw_uuid(id), do: if(Mydia.DB.postgres?(), do: Ecto.UUID.dump!(id), else: id)

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

  describe "rate_item/3" do
    test "a thumbs down removes the card and remembers the title" do
      user = user_fixture()
      shelf = shelf_fixture(user)
      item = shelf_item_fixture(shelf, %{media_type: :tv_show, provider_id: 55})
      id = item.id

      assert {:ok, %ShelfItem{id: ^id}} = Shelves.rate_item(user, item.id, :down)

      assert Repo.aggregate(ShelfItem, :count) == 0
      assert MapSet.member?(Shelves.dismissed_keys(shelf), ProviderKey.new(:tv_show, :tmdb, 55))

      assert %ShelfFeedback{rating: :down, via: nil, title: "Ember Tide", year: 2024} =
               Repo.one!(ShelfFeedback)
    end

    test "a thumbs up is recorded as seen" do
      user = user_fixture()
      item = shelf_item_fixture(shelf_fixture(user))

      assert {:ok, _} = Shelves.rate_item(user, item.id, :up)
      assert %ShelfFeedback{rating: :up, via: :seen} = Repo.one!(ShelfFeedback)
      assert Repo.aggregate(ShelfItem, :count) == 0
    end

    test "rating the same title again replaces the rating" do
      user = user_fixture()
      shelf = shelf_fixture(user)

      assert {:ok, _} = Shelves.rate_item(user, shelf_item_fixture(shelf).id, :down)
      assert {:ok, _} = Shelves.rate_item(user, shelf_item_fixture(shelf).id, :up)

      assert %ShelfFeedback{rating: :up, via: :seen} = Repo.one!(ShelfFeedback)
    end

    test "an item whose row is already gone is not found and does not raise" do
      user = user_fixture()
      item = shelf_item_fixture(shelf_fixture(user))
      Repo.delete!(item)

      assert {:error, :not_found} = Shelves.rate_item(user, item.id, :down)
      assert Repo.aggregate(ShelfFeedback, :count) == 0
    end

    test "refuses another user's item and an unknown id" do
      item = shelf_item_fixture(shelf_fixture(user_fixture()))

      assert {:error, :not_found} = Shelves.rate_item(user_fixture(), item.id, :down)
      assert {:error, :not_found} = Shelves.rate_item(user_fixture(), Ecto.UUID.generate(), :up)
      assert {:error, :not_found} = Shelves.rate_item(user_fixture(), "not-a-uuid", :down)
      assert Repo.aggregate(ShelfItem, :count) == 1
    end

    test "a legacy row without a rating reads back as down" do
      user = user_fixture()

      Repo.insert_all("plugin_shelf_dismissals", [
        %{
          id: raw_uuid(Ecto.UUID.generate()),
          plugin_slug: "shelf-test",
          shelf_key: "picks",
          user_id: raw_uuid(user.id),
          media_type: "movie",
          provider: "tmdb",
          provider_id: 9,
          inserted_at: @now
        }
      ])

      assert %ShelfFeedback{rating: :down, via: nil, title: nil} = Repo.one!(ShelfFeedback)
    end

    test "dismissed_keys/1 covers both ratings" do
      user = user_fixture()
      shelf = shelf_fixture(user)
      Shelves.rate_item(user, shelf_item_fixture(shelf, %{provider_id: 1}).id, :down)
      Shelves.rate_item(user, shelf_item_fixture(shelf, %{provider_id: 2}).id, :up)

      assert Shelves.dismissed_keys(shelf) ==
               MapSet.new([ProviderKey.new(:movie, :tmdb, 1), ProviderKey.new(:movie, :tmdb, 2)])
    end
  end

  describe "feedback/1" do
    test "reports a tvdb title with tvdb_id set and tmdb_id nil" do
      user = user_fixture()
      shelf = shelf_fixture(user)
      item = shelf_item_fixture(shelf, %{provider: :tvdb, provider_id: 77, media_type: :tv_show})
      Shelves.rate_item(user, item.id, :up)

      assert [%{media_type: :tv_show, tvdb_id: 77, tmdb_id: nil, rating: :up, via: :seen}] =
               Shelves.feedback(shelf)
    end
  end

  describe "record_added/2" do
    test "records an up/added rating and keeps the card" do
      user = user_fixture()
      shelf = shelf_fixture(user)
      item = shelf_item_fixture(shelf)

      assert :ok = Shelves.record_added(user, item.id)

      assert Repo.aggregate(ShelfItem, :count) == 1
      assert %ShelfFeedback{rating: :up, via: :added} = Repo.one!(ShelfFeedback)
      assert Shelves.added_item_keys(shelf) == MapSet.new([ProviderKey.new(:movie, :tmdb, 101)])
    end

    test "refuses another user's item" do
      item = shelf_item_fixture(shelf_fixture(user_fixture()))

      assert {:error, :not_found} = Shelves.record_added(user_fixture(), item.id)
      assert Repo.aggregate(ShelfFeedback, :count) == 0
    end
  end

  describe "undo_rating/2" do
    test "puts the card back in place and clears the rating" do
      user = user_fixture()
      shelf = shelf_fixture(user, filled_at: @now)
      item = shelf_item_fixture(shelf, %{position: 3, inserted_at: @now, updated_at: @now})
      {:ok, deleted} = Shelves.rate_item(user, item.id, :down)

      assert :ok = Shelves.undo_rating(user, deleted)

      assert %ShelfItem{position: 3} = Repo.get!(ShelfItem, item.id)
      assert Repo.aggregate(ShelfFeedback, :count) == 0
    end

    test "undoing twice does not raise" do
      user = user_fixture()
      shelf = shelf_fixture(user, filled_at: @now)
      item = shelf_item_fixture(shelf, %{inserted_at: @now, updated_at: @now})
      {:ok, deleted} = Shelves.rate_item(user, item.id, :down)

      assert :ok = Shelves.undo_rating(user, deleted)
      assert :ok = Shelves.undo_rating(user, deleted)
      assert Repo.aggregate(ShelfItem, :count) == 1
    end

    test "a purged shelf or another user's shelf is not restored and does not raise" do
      user = user_fixture()
      shelf = shelf_fixture(user, filled_at: @now)
      item = shelf_item_fixture(shelf, %{inserted_at: @now, updated_at: @now})
      {:ok, deleted} = Shelves.rate_item(user, item.id, :down)

      assert {:ok, :not_restored} = Shelves.undo_rating(user_fixture(), deleted)
      assert Repo.aggregate(ShelfItem, :count) == 0

      Shelves.purge("shelf-test")
      assert {:ok, :not_restored} = Shelves.undo_rating(user, deleted)
    end

    test "after a refill the rating is cleared but the card is not restored" do
      user = user_fixture()
      shelf = shelf_fixture(user, filled_at: @now)
      item = shelf_item_fixture(shelf, %{inserted_at: @now, updated_at: @now})
      {:ok, deleted} = Shelves.rate_item(user, item.id, :down)

      later = DateTime.add(@now, 60)
      shelf |> Ecto.Changeset.change(filled_at: later) |> Repo.update!()
      shelf_item_fixture(shelf, %{position: 1, inserted_at: later, updated_at: later})

      assert {:ok, :not_restored} = Shelves.undo_rating(user, deleted)
      assert Repo.aggregate(ShelfItem, :count) == 1
      assert Repo.aggregate(ShelfFeedback, :count) == 0
    end

    test "after an access reset the card is not restored" do
      user = user_fixture()
      shelf = shelf_fixture(user, filled_at: @now)
      item = shelf_item_fixture(shelf, %{inserted_at: @now, updated_at: @now})
      {:ok, deleted} = Shelves.rate_item(user, item.id, :down)

      assert :ok = Shelves.reset_for_user(user.id)

      assert {:ok, :not_restored} = Shelves.undo_rating(user, deleted)
      assert Repo.aggregate(ShelfItem, :count) == 0
    end

    test "a too-few refill that kept the old cards still restores the card" do
      user = user_fixture()
      shelf = shelf_fixture(user, filled_at: @now)
      item = shelf_item_fixture(shelf, %{inserted_at: @now, updated_at: @now})
      kept = shelf_item_fixture(shelf, %{position: 1, inserted_at: @now, updated_at: @now})
      {:ok, deleted} = Shelves.rate_item(user, item.id, :down)

      shelf |> Ecto.Changeset.change(filled_at: DateTime.add(@now, 60)) |> Repo.update!()

      assert :ok = Shelves.undo_rating(user, deleted)
      assert Repo.get(ShelfItem, item.id)
      assert Repo.get(ShelfItem, kept.id)
    end

    test "a too-few fill after an access reset does not restore the card" do
      user = user_fixture()
      shelf = shelf_fixture(user, filled_at: @now)
      item = shelf_item_fixture(shelf, %{inserted_at: @now, updated_at: @now})
      {:ok, deleted} = Shelves.rate_item(user, item.id, :down)

      assert :ok = Shelves.reset_for_user(user.id)
      shelf |> Ecto.Changeset.change(filled_at: DateTime.add(@now, 60)) |> Repo.update!()

      assert {:ok, :not_restored} = Shelves.undo_rating(user, deleted)
      assert Repo.aggregate(ShelfItem, :count) == 0
    end

    test "rating every card leaves the shelf empty and undo still restores" do
      user = user_fixture()
      shelf = shelf_fixture(user, filled_at: @now)
      item = shelf_item_fixture(shelf, %{inserted_at: @now, updated_at: @now})
      {:ok, deleted} = Shelves.rate_item(user, item.id, :down)
      assert Repo.aggregate(ShelfItem, :count) == 0

      assert :ok = Shelves.undo_rating(user, deleted)
      assert Repo.get(ShelfItem, item.id)
    end
  end

  describe "reset_for_user/1" do
    test "clears the user's items, marks the shelf stale, keeps ratings, spares others" do
      user = user_fixture()
      other = user_fixture()
      far = DateTime.add(DateTime.utc_now(), 80_000)

      mine = shelf_fixture(user, filled_at: DateTime.utc_now(), stale_at: far)
      Shelves.rate_item(user, shelf_item_fixture(mine).id, :down)
      shelf_item_fixture(mine, %{provider_id: 2})

      theirs = shelf_fixture(other, filled_at: DateTime.utc_now(), stale_at: far)
      shelf_item_fixture(theirs, %{provider_id: 3})

      Shelves.subscribe(user)
      assert :ok = Shelves.reset_for_user(user.id)

      mine_id = mine.id
      assert_receive {:shelf_updated, ^mine_id}

      assert Repo.all(from i in ShelfItem, where: i.shelf_id == ^mine.id) == []
      reloaded = Repo.get!(Shelf, mine.id)
      assert reloaded.stale_at == nil
      assert reloaded.filled_at == nil
      assert Shelves.stale?(reloaded, DateTime.utc_now())
      assert MapSet.size(Shelves.dismissed_keys(mine)) == 1

      assert [%ShelfItem{}] = Repo.all(from i in ShelfItem, where: i.shelf_id == ^theirs.id)
      assert Repo.get!(Shelf, theirs.id).stale_at == far
    end

    test "is a no-op for a user without shelves" do
      assert :ok = Shelves.reset_for_user(user_fixture().id)
    end
  end

  describe "failure_summary/1" do
    defp failed!(shelf, message, updated_at) do
      shelf
      |> Ecto.Changeset.change(
        status: :failed,
        failure_count: 1,
        last_error: message,
        updated_at: updated_at
      )
      |> Repo.update!()
    end

    test "counts failed shelves and reports the newest error" do
      older = failed!(shelf_fixture(user_fixture()), "old error", ~U[2026-10-01 10:00:00.000000Z])
      newer = failed!(shelf_fixture(user_fixture()), "new error", ~U[2026-10-01 11:00:00.000000Z])
      shelf_fixture(user_fixture())

      assert %{failing: 2, last_error: "new error"} = Shelves.failure_summary("shelf-test")
      assert older.id != newer.id
    end

    test "is empty when nothing fails or the plugin has no shelves" do
      shelf_fixture(user_fixture())

      assert %{failing: 0, last_error: nil} = Shelves.failure_summary("shelf-test")
      assert %{failing: 0, last_error: nil} = Shelves.failure_summary("nobody")
    end
  end

  describe "purge/1" do
    test "deletes a plugin's shelves, items and dismissals and nobody else's" do
      user = user_fixture()
      mine = shelf_fixture(user)
      Shelves.rate_item(user, shelf_item_fixture(mine).id, :down)
      shelf_item_fixture(mine, %{provider_id: 2})
      other = shelf_fixture(user, slug: "other-plugin")

      assert :ok = Shelves.purge("shelf-test")

      assert [%Shelf{id: id}] = Repo.all(Shelf)
      assert id == other.id
      assert Repo.aggregate(ShelfItem, :count) == 0
      assert Repo.aggregate(ShelfFeedback, :count) == 0
    end
  end
end
