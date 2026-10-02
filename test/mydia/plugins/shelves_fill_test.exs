defmodule Mydia.Plugins.ShelvesFillTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.AccountsFixtures
  import Mydia.ShelfHelpers

  alias Mydia.Jobs.ShelfFill
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Shelf
  alias Mydia.Plugins.ShelfDismissal
  alias Mydia.Plugins.ShelfItem
  alias Mydia.Plugins.Shelves

  @now ~U[2026-10-01 12:00:00.000000Z]

  setup do
    register_shelf_plugin!(ttl_seconds: 86_400)
    user = user_fixture()

    {:ok,
     user: user, shelf: shelf_fixture(user), declared: Shelves.get_declared("shelf-test", "picks")}
  end

  defp wit(id, type \\ "movie") do
    %{item: %{media_type: type, tmdb_id: id, tvdb_id: nil, imdb_id: nil}, reason: "Reason #{id}"}
  end

  defp returning(result) do
    test = self()

    fn slug, key, user, opts ->
      send(test, {:invoked, slug, key, user.id, opts})
      result
    end
  end

  defp resolver do
    fn {provider, id}, type ->
      {:ok,
       %MediaMetadata{
         provider_id: to_string(id),
         provider: provider,
         media_type: type,
         title: "Title #{id}",
         year: 2024,
         genres: ["Drama"],
         content_rating: "PG"
       }}
    end
  end

  defp fill(shelf, declared, invoker, opts \\ []) do
    defaults = [now: @now, invoker: invoker, resolver: resolver()]
    Shelves.fill(shelf, declared, Keyword.merge(defaults, opts))
  end

  defp titles(shelf) do
    Repo.all(
      from i in ShelfItem, where: i.shelf_id == ^shelf.id, order_by: i.position, select: i.title
    )
  end

  test "stores verified picks, resets bookkeeping and broadcasts", ctx do
    Shelves.subscribe(ctx.user)
    invoker = returning({:ok, %{items: [wit(1), wit(2), wit(3)]}})

    assert :filled = fill(ctx.shelf, ctx.declared, invoker)

    assert titles(ctx.shelf) == ["Title 1", "Title 2", "Title 3"]

    shelf = Repo.get!(Shelf, ctx.shelf.id)
    assert shelf.status == :idle
    assert shelf.filled_at == @now
    assert shelf.stale_at == DateTime.add(@now, 86_400)
    assert shelf.failure_count == 0
    assert shelf.last_error == nil

    shelf_id = ctx.shelf.id
    assert_receive {:shelf_updated, ^shelf_id}
  end

  test "asks for twice the rail and passes the current items and dismissals as exclude", ctx do
    Shelves.dismiss_item(ctx.user, shelf_item_fixture(ctx.shelf, %{provider_id: 50}).id)
    shelf_item_fixture(ctx.shelf, %{provider_id: 60, media_type: :tv_show})

    fill(ctx.shelf, ctx.declared, returning({:ok, %{items: []}}))

    user_id = ctx.user.id
    assert_receive {:invoked, "shelf-test", "picks", ^user_id, opts}
    assert opts[:limit] == 24
    assert opts[:now] == @now

    assert Enum.sort_by(opts[:exclude], & &1.tmdb_id) == [
             %{media_type: :movie, tmdb_id: 50, tvdb_id: nil, imdb_id: nil},
             %{media_type: :tv_show, tmdb_id: 60, tvdb_id: nil, imdb_id: nil}
           ]
  end

  test "a new fill replaces the old items", ctx do
    shelf_item_fixture(ctx.shelf, %{provider_id: 99, title: "The Long Thaw"})

    assert :filled =
             fill(ctx.shelf, ctx.declared, returning({:ok, %{items: [wit(1), wit(2), wit(3)]}}))

    assert titles(ctx.shelf) == ["Title 1", "Title 2", "Title 3"]
  end

  test "too few survivors keeps the old list, counts as done and does not broadcast", ctx do
    Shelves.subscribe(ctx.user)
    shelf_item_fixture(ctx.shelf, %{provider_id: 99, title: "The Long Thaw"})

    assert :kept = fill(ctx.shelf, ctx.declared, returning({:ok, %{items: [wit(1)]}}))

    assert titles(ctx.shelf) == ["The Long Thaw"]
    shelf = Repo.get!(Shelf, ctx.shelf.id)
    assert shelf.stale_at == DateTime.add(@now, 86_400)
    assert shelf.status == :idle
    refute_receive {:shelf_updated, _}
  end

  test "a dismissed title is not stored even when the plugin returns it", ctx do
    Shelves.dismiss_item(ctx.user, shelf_item_fixture(ctx.shelf, %{provider_id: 2}).id)

    assert :filled =
             fill(
               ctx.shelf,
               ctx.declared,
               returning({:ok, %{items: [wit(1), wit(2), wit(3), wit(4)]}})
             )

    assert titles(ctx.shelf) == ["Title 1", "Title 3", "Title 4"]
  end

  test "a plugin error marks the shelf failed, keeps items and backs off", ctx do
    shelf_item_fixture(ctx.shelf, %{provider_id: 99, title: "The Long Thaw"})
    failing = returning({:error, Error.new(:guest_error, "The model server answered 401")})

    assert :failed = fill(ctx.shelf, ctx.declared, failing)

    shelf = Repo.get!(Shelf, ctx.shelf.id)
    assert shelf.status == :failed
    assert shelf.failure_count == 1
    assert shelf.last_error == "The model server answered 401"
    assert shelf.stale_at == DateTime.add(@now, 3_600)
    assert titles(ctx.shelf) == ["The Long Thaw"]

    assert :failed = fill(shelf, ctx.declared, failing)
    assert Repo.get!(Shelf, shelf.id).stale_at == DateTime.add(@now, 21_600)

    assert :failed = fill(Repo.get!(Shelf, shelf.id), ctx.declared, failing)
    third = Repo.get!(Shelf, shelf.id)
    assert third.failure_count == 3
    assert third.stale_at == DateTime.add(@now, 86_400)
  end

  test "an unreachable relay fails the fill as a whole", ctx do
    down = fn _ref, _type -> {:error, :timeout} end

    assert :failed =
             fill(
               ctx.shelf,
               ctx.declared,
               returning({:ok, %{items: [wit(1), wit(2), wit(3)]}}),
               resolver: down
             )

    assert titles(ctx.shelf) == []
    assert Repo.get!(Shelf, ctx.shelf.id).last_error =~ "metadata"
  end

  test "a busy plugin leaves the shelf untouched", ctx do
    assert :busy =
             fill(ctx.shelf, ctx.declared, returning({:error, Error.new(:busy, "in flight")}))

    assert %Shelf{stale_at: nil, failure_count: 0, status: :idle} =
             Repo.get!(Shelf, ctx.shelf.id)
  end

  test "a long error is clipped to fit the column", ctx do
    long = returning({:error, Error.new(:guest_error, String.duplicate("x", 900))})

    assert :failed = fill(ctx.shelf, ctx.declared, long)
    assert String.length(Repo.get!(Shelf, ctx.shelf.id).last_error) == 500
  end

  test "a dismissal recorded while the plugin runs is honoured", ctx do
    user_id = ctx.user.id

    invoker = fn _slug, _key, _user, _opts ->
      Repo.insert!(%ShelfDismissal{
        plugin_slug: "shelf-test",
        shelf_key: "picks",
        user_id: user_id,
        media_type: :movie,
        provider: :tmdb,
        provider_id: 2
      })

      {:ok, %{items: [wit(1), wit(2), wit(3), wit(4)]}}
    end

    assert :filled = fill(ctx.shelf, ctx.declared, invoker)
    assert titles(ctx.shelf) == ["Title 1", "Title 3", "Title 4"]
  end

  test "request_fill returns :ok and does not raise when Oban is not running", ctx do
    assert :ok = Shelves.request_fill(ctx.shelf)
    assert [%Oban.Job{args: %{"shelf_id" => id}}] = all_enqueued(worker: ShelfFill)
    assert id == ctx.shelf.id
  end

  test "refresh_stale enqueues one job per stale shelf and none for a fresh one", ctx do
    # The fallback insert does not enforce `unique:`, so this one needs Oban.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    views = Shelves.list_for(ctx.user, :home, @now)
    assert :ok = Shelves.refresh_stale(views)
    assert :ok = Shelves.refresh_stale(views)

    assert [%Oban.Job{args: %{"shelf_id" => id}}] = all_enqueued(worker: ShelfFill)
    assert id == ctx.shelf.id

    fresh = user_fixture()
    shelf_fixture(fresh, filled_at: @now, stale_at: DateTime.add(@now, 60))
    Shelves.refresh_stale(Shelves.list_for(fresh, :home, @now))
    assert length(all_enqueued(worker: ShelfFill)) == 1
  end
end
