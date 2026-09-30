defmodule Mydia.Plugins.PageWritesTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Collections
  alias Mydia.Playback
  alias Mydia.Plugins.PageWrites

  @origin "plugin:helper"

  setup do
    {:ok, user: user_fixture(), movie: media_item_fixture(%{title: "Harbor of Glass"})}
  end

  describe "watch_state" do
    test "marks watched and undoes back to no progress", %{user: user, movie: movie} do
      args = %{"content" => %{"media_item_id" => movie.id}, "watched" => true}

      assert {:ok, %{"status" => "changed"}, inverse} =
               PageWrites.execute("watch_state", args, user, @origin)

      assert Playback.get_progress(user.id, media_item_id: movie.id).watched

      assert :ok = PageWrites.undo("watch_state", args, %{}, inverse, user, @origin)
      assert Playback.get_progress(user.id, media_item_id: movie.id) == nil
    end

    test "undo restores an earlier position", %{user: user, movie: movie} do
      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: movie.id], %{
          position_seconds: 300,
          duration_seconds: 1000
        })

      args = %{"content" => %{"media_item_id" => movie.id}, "watched" => true}
      {:ok, _, inverse} = PageWrites.execute("watch_state", args, user, @origin)

      assert :ok = PageWrites.undo("watch_state", args, %{}, inverse, user, @origin)
      restored = Playback.get_progress(user.id, media_item_id: movie.id)
      assert restored.position_seconds == 300
      refute restored.watched
    end

    test "undo refuses when the state changed since", %{user: user, movie: movie} do
      args = %{"content" => %{"media_item_id" => movie.id}, "watched" => true}
      {:ok, _, inverse} = PageWrites.execute("watch_state", args, user, @origin)

      {:ok, _} =
        Playback.save_progress(
          user.id,
          [media_item_id: movie.id],
          %{position_seconds: 10, duration_seconds: 1000, watched: false},
          authoritative_watched: true
        )

      assert {:error, :conflict} =
               PageWrites.undo("watch_state", args, %{}, inverse, user, @origin)
    end
  end

  describe "favorite_add" do
    test "adds, is a noop when present, and undoes", %{user: user, movie: movie} do
      args = %{"media_item_id" => movie.id}

      assert {:ok, %{"status" => "changed"}, inverse} =
               PageWrites.execute("favorite_add", args, user, @origin)

      assert Collections.is_favorite?(Scope.for_user(user), movie.id)

      assert {:ok, %{"status" => "already-favorited"}, :noop} =
               PageWrites.execute("favorite_add", args, user, @origin)

      assert :ok = PageWrites.undo("favorite_add", args, %{}, inverse, user, @origin)
      refute Collections.is_favorite?(Scope.for_user(user), movie.id)
    end
  end

  describe "collections" do
    test "create, add, remove, update, and undo each", %{user: user, movie: movie} do
      {:ok, %{"id" => id}, create_inv} =
        PageWrites.execute(
          "collection_create",
          %{"name" => "Rainy Sundays", "type" => "manual"},
          user,
          @origin
        )

      add_args = %{"id" => id, "media_item_ids" => [movie.id]}

      {:ok, %{"added" => 1}, add_inv} =
        PageWrites.execute("collection_add_items", add_args, user, @origin)

      upd_args = %{"id" => id, "attrs" => %{"name" => "Rainy Days"}}
      {:ok, _, upd_inv} = PageWrites.execute("collection_update", upd_args, user, @origin)
      assert Collections.get_collection(user, id).name == "Rainy Days"

      assert :ok = PageWrites.undo("collection_update", upd_args, %{}, upd_inv, user, @origin)
      assert Collections.get_collection(user, id).name == "Rainy Sundays"

      assert :ok = PageWrites.undo("collection_add_items", add_args, %{}, add_inv, user, @origin)

      assert Collections.item_ids_in(Collections.get_collection(user, id), [movie.id]) ==
               MapSet.new()

      assert :ok =
               PageWrites.undo("collection_create", %{}, %{"id" => id}, create_inv, user, @origin)

      assert Collections.get_collection(user, id) == nil
    end

    test "remove_items undoes by putting the items back", %{user: user, movie: movie} do
      {:ok, c} = Collections.create_collection(user, %{name: "Shelf", type: "manual"})
      {:ok, _} = Collections.add_item(c, movie.id)
      args = %{"id" => c.id, "media_item_ids" => [movie.id]}

      {:ok, %{"removed" => 1}, inverse} =
        PageWrites.execute("collection_remove_items", args, user, @origin)

      assert :ok = PageWrites.undo("collection_remove_items", args, %{}, inverse, user, @origin)
      assert Collections.item_ids_in(c, [movie.id]) == MapSet.new([movie.id])
    end

    test "undoing a create refuses once the collection was renamed", %{user: user} do
      {:ok, %{"id" => id}, inverse} =
        PageWrites.execute(
          "collection_create",
          %{"name" => "Rainy Sundays", "type" => "manual"},
          user,
          @origin
        )

      c = Collections.get_collection(user, id)
      {:ok, _} = Collections.update_collection(user, c, %{name: "Renamed by hand"})

      assert {:error, :conflict} =
               PageWrites.undo("collection_create", %{}, %{"id" => id}, inverse, user, @origin)

      assert Collections.get_collection(user, id)
    end

    test "undoing a create refuses once an item was added", %{user: user, movie: movie} do
      {:ok, %{"id" => id}, inverse} =
        PageWrites.execute(
          "collection_create",
          %{"name" => "Rainy Sundays", "type" => "manual"},
          user,
          @origin
        )

      {:ok, _} = Collections.add_item(Collections.get_collection(user, id), movie.id)

      assert {:error, :conflict} =
               PageWrites.undo("collection_create", %{}, %{"id" => id}, inverse, user, @origin)
    end

    test "undoing an update refuses once the field changed again", %{user: user} do
      {:ok, c} = Collections.create_collection(user, %{name: "Shelf", type: "manual"})
      args = %{"id" => c.id, "attrs" => %{"name" => "Shelf Two"}}
      {:ok, _, inverse} = PageWrites.execute("collection_update", args, user, @origin)

      {:ok, _} =
        Collections.update_collection(user, Collections.get_collection(user, c.id), %{
          name: "Shelf Three"
        })

      assert {:error, :conflict} =
               PageWrites.undo("collection_update", args, %{}, inverse, user, @origin)

      assert Collections.get_collection(user, c.id).name == "Shelf Three"
    end

    test "cannot write another user's collection", %{user: user, movie: movie} do
      other = user_fixture()
      {:ok, c} = Collections.create_collection(other, %{name: "Theirs", type: "manual"})

      assert {:error, %{type: :not_found}} =
               PageWrites.execute(
                 "collection_add_items",
                 %{"id" => c.id, "media_item_ids" => [movie.id]},
                 user,
                 @origin
               )
    end
  end

  describe "media_request" do
    test "creates a request for a guest and undo cancels it" do
      guest = user_fixture(%{role: "guest"})

      args = %{
        "media_type" => "movie",
        "tmdb_id" => 900_002,
        "title" => "The Tin Orchard",
        "year" => 2031
      }

      {:ok, %{"request_id" => rid}, inverse} =
        PageWrites.execute("media_request", args, guest, @origin)

      assert :ok =
               PageWrites.undo(
                 "media_request",
                 args,
                 %{"request_id" => rid},
                 inverse,
                 guest,
                 @origin
               )

      assert_raise Ecto.NoResultsError, fn -> Mydia.MediaRequests.get_request!(rid) end
    end
  end

  describe "media_add undo" do
    setup %{user: user} do
      {:ok, item} =
        Mydia.Media.create_media_item(Scope.for_user(user), %{
          type: "movie",
          title: "The Tin Orchard",
          year: 2031,
          tmdb_id: 900_003,
          monitored: true
        })

      {:ok, inverse: %{"media_item_id" => item.id}, item: item}
    end

    test "removes an item the write created and refuses once it is gone", %{
      user: user,
      inverse: inverse
    } do
      assert :ok = PageWrites.undo("media_add", %{}, %{}, inverse, user, @origin)
      assert {:error, :conflict} = PageWrites.undo("media_add", %{}, %{}, inverse, user, @origin)
    end

    test "refuses when a movie file exists", %{user: user, item: item, inverse: inverse} do
      media_file_fixture(%{media_item_id: item.id})

      assert {:error, :conflict} = PageWrites.undo("media_add", %{}, %{}, inverse, user, @origin)
      assert Mydia.Media.get_media_item!(Scope.for_user(user), item.id)
    end

    test "refuses when a show has an imported episode file", %{user: user} do
      show = media_item_fixture(%{type: "tv_show", title: "Lantern Row"})
      episode = episode_fixture(%{media_item_id: show.id})
      media_file_fixture(%{episode_id: episode.id})

      assert {:error, :conflict} =
               PageWrites.undo(
                 "media_add",
                 %{},
                 %{},
                 %{"media_item_id" => show.id},
                 user,
                 @origin
               )

      assert Mydia.Media.get_media_item!(Scope.for_user(user), show.id)
    end

    test "refuses when another user favorited it", %{user: user, item: item, inverse: inverse} do
      {:ok, :added} = Collections.toggle_favorite(user_fixture(), item.id)

      assert {:error, :conflict} = PageWrites.undo("media_add", %{}, %{}, inverse, user, @origin)
    end

    test "refuses when another user has progress on it", %{
      user: user,
      item: item,
      inverse: inverse
    } do
      {:ok, _} =
        Playback.save_progress(user_fixture().id, [media_item_id: item.id], %{
          position_seconds: 5,
          duration_seconds: 100
        })

      assert {:error, :conflict} = PageWrites.undo("media_add", %{}, %{}, inverse, user, @origin)
    end

    test "refuses a user who may not delete media", %{item: item, inverse: inverse} do
      guest = user_fixture(%{role: "guest"})

      assert {:error, %{type: :capability_denied}} =
               PageWrites.undo("media_add", %{}, %{}, inverse, guest, @origin)

      assert Mydia.Media.get_media_item!(Scope.system(), item.id)
    end
  end

  describe "system collections" do
    test "collections:write ops cannot touch Favorites", %{user: user, movie: movie} do
      {:ok, favorites} = Collections.get_or_create_favorites(user)

      assert {:error, %{type: :not_found}} =
               PageWrites.execute(
                 "collection_add_items",
                 %{"id" => favorites.id, "media_item_ids" => [movie.id]},
                 user,
                 @origin
               )

      assert {:error, %{type: :not_found}} =
               PageWrites.execute(
                 "collection_update",
                 %{"id" => favorites.id, "attrs" => %{"name" => "Mine"}},
                 user,
                 @origin
               )

      assert {:error, %{type: :not_found}} =
               PageWrites.execute(
                 "collection_remove_items",
                 %{"id" => favorites.id, "media_item_ids" => [movie.id]},
                 user,
                 @origin
               )
    end
  end

  describe "add_items undo atomicity" do
    test "a conflict removes nothing", %{user: user, movie: movie} do
      other = media_item_fixture(%{title: "Salt Meridian"})
      {:ok, c} = Collections.create_collection(user, %{name: "Shelf", type: "manual"})
      args = %{"id" => c.id, "media_item_ids" => [movie.id, other.id]}
      {:ok, _, inverse} = PageWrites.execute("collection_add_items", args, user, @origin)
      {:ok, _} = Collections.remove_item(c, other.id)

      assert {:error, :conflict} =
               PageWrites.undo("collection_add_items", args, %{}, inverse, user, @origin)

      assert Collections.item_ids_in(c, [movie.id]) == MapSet.new([movie.id])
    end
  end

  test "surface/1 maps every op" do
    for op <-
          ~w(watch_state favorite_add collection_create collection_update collection_add_items collection_remove_items media_request media_add) do
      assert is_binary(PageWrites.surface(op))
    end
  end
end
