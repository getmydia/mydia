defmodule Mydia.Plugins.ShelvesStaleTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.ShelfHelpers

  alias Mydia.Plugins.Dispatcher
  alias Mydia.Plugins.Shelf
  alias Mydia.Plugins.Shelves

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

    pid =
      start_supervised!(
        {Dispatcher,
         name: :"disp_stale_#{System.unique_integer([:positive])}", invoker: fn _, _ -> :ok end}
      )

    # Straight to the instance under test. A PubSub broadcast would also reach
    # the application's own dispatcher, which would then do the work and let
    # this pass even with the instance below unwired.
    send(pid, {:event_created, event(user)})

    # handle_info has run once this returns, so every task it started exists.
    _ = :sys.get_state(pid)
    await_tasks(Task.Supervisor.children(Mydia.TaskSupervisor))

    assert DateTime.compare(stale_at(shelf), far) == :lt
  end

  # Waits for each task to exit, by monitor rather than by polling the database.
  defp await_tasks(pids) do
    refs = for pid <- pids, do: Process.monitor(pid)

    for ref <- refs do
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 10_000
    end
  end
end
