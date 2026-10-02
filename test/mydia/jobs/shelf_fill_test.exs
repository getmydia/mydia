defmodule Mydia.Jobs.ShelfFillTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.AccountsFixtures
  import Mydia.ShelfHelpers

  alias Mydia.Jobs.ShelfFill
  alias Mydia.Plugins.Shelf

  test "an unknown shelf is a no-op" do
    assert :ok = perform_job(ShelfFill, %{"shelf_id" => Ecto.UUID.generate()})
  end

  test "a shelf whose plugin no longer declares it is a no-op" do
    shelf = shelf_fixture(user_fixture(), slug: "gone")

    assert :ok = perform_job(ShelfFill, %{"shelf_id" => shelf.id})
    assert %Shelf{stale_at: nil, failure_count: 0} = Repo.get!(Shelf, shelf.id)
  end

  test "a shelf that is no longer stale is left alone" do
    register_shelf_plugin!()
    future = DateTime.add(DateTime.utc_now(), 3_600)
    shelf = shelf_fixture(user_fixture(), filled_at: DateTime.utc_now(), stale_at: future)

    assert :ok = perform_job(ShelfFill, %{"shelf_id" => shelf.id})
    assert Repo.get!(Shelf, shelf.id).stale_at == future
  end

  test "a stale shelf whose plugin is not running records the failure" do
    register_shelf_plugin!()
    shelf = shelf_fixture(user_fixture())

    assert :ok = perform_job(ShelfFill, %{"shelf_id" => shelf.id})

    assert %Shelf{status: :failed, failure_count: 1} = Repo.get!(Shelf, shelf.id)
  end

  test "jobs are unique per shelf" do
    # The app skips Oban in test, so start an isolated manual-mode instance.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    id = Ecto.UUID.generate()

    assert {:ok, %Oban.Job{conflict?: false}} = Oban.insert(ShelfFill.new(%{shelf_id: id}))
    assert {:ok, %Oban.Job{conflict?: true}} = Oban.insert(ShelfFill.new(%{shelf_id: id}))
  end
end
