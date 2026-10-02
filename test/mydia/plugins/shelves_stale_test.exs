defmodule Mydia.Plugins.ShelvesStaleTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.ShelfHelpers

  alias Mydia.Plugins.Dispatcher
  alias Mydia.Plugins.Shelf
  alias Mydia.Plugins.Shelves
  alias Phoenix.PubSub

  @now ~U[2026-10-01 12:00:00.000000Z]

  defp event(user, type \\ "playback.finished", actor_type \\ :user),
    do: %{type: type, actor_type: actor_type, actor_id: user.id}

  defp stale_at(shelf), do: Repo.get!(Shelf, shelf.id).stale_at

  setup do
    register_shelf_plugin!(refresh_on: ["playback.finished"])
    {:ok, user: user_fixture()}
  end

  test "a named event pulls stale_at forward to now", %{user: user} do
    filled = DateTime.add(@now, -7_200)
    shelf = shelf_fixture(user, filled_at: filled, stale_at: DateTime.add(@now, 80_000))

    assert :ok = Shelves.mark_stale(event(user), @now)
    assert stale_at(shelf) == @now
  end

  test "a shelf filled under an hour ago waits out the hour", %{user: user} do
    filled = DateTime.add(@now, -600)
    shelf = shelf_fixture(user, filled_at: filled, stale_at: DateTime.add(@now, 80_000))

    Shelves.mark_stale(event(user), @now)
    assert stale_at(shelf) == DateTime.add(filled, 3_600)
  end

  test "never pushes stale_at later", %{user: user} do
    soon = DateTime.add(@now, -60)
    shelf = shelf_fixture(user, filled_at: DateTime.add(@now, -90_000), stale_at: soon)

    Shelves.mark_stale(event(user), @now)
    assert stale_at(shelf) == soon
  end

  test "leaves a never-filled shelf alone", %{user: user} do
    shelf = shelf_fixture(user)

    Shelves.mark_stale(event(user), @now)
    assert stale_at(shelf) == nil
  end

  test "ignores other users, other events and non-user actors", %{user: user} do
    later = DateTime.add(@now, 80_000)
    shelf = shelf_fixture(user, filled_at: DateTime.add(@now, -7_200), stale_at: later)

    Shelves.mark_stale(event(user_fixture()), @now)
    Shelves.mark_stale(event(user, "playback.started"), @now)
    Shelves.mark_stale(event(user, "playback.finished", :system), @now)
    Shelves.mark_stale(%{type: "playback.finished"}, @now)

    assert stale_at(shelf) == later
  end

  test "accepts the actor type as a string", %{user: user} do
    shelf =
      shelf_fixture(user,
        filled_at: DateTime.add(@now, -7_200),
        stale_at: DateTime.add(@now, 80_000)
      )

    Shelves.mark_stale(event(user, "playback.finished", "user"), @now)
    assert stale_at(shelf) == @now
  end

  test "the dispatcher marks shelves stale when the event arrives", %{user: user} do
    far = DateTime.add(DateTime.utc_now(), 80_000)

    shelf =
      shelf_fixture(user, filled_at: DateTime.add(DateTime.utc_now(), -7_200), stale_at: far)

    start_supervised!(
      {Dispatcher,
       name: :"disp_stale_#{System.unique_integer([:positive])}", invoker: fn _, _ -> :ok end}
    )

    PubSub.broadcast(Mydia.PubSub, "events:all", {:event_created, event(user)})

    assert eventually(fn -> DateTime.compare(stale_at(shelf), far) == :lt end)
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end
end
