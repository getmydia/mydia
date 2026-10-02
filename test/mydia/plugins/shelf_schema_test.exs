defmodule Mydia.Plugins.ShelfSchemaTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Plugins.Shelf
  alias Mydia.Plugins.ShelfDismissal
  alias Mydia.Plugins.ShelfItem

  defp shelf!(user, key \\ "picks") do
    Repo.insert!(%Shelf{plugin_slug: "shelfy", shelf_key: key, user_id: user.id})
  end

  test "a shelf starts idle, never filled, with no failures" do
    shelf = shelf!(user_fixture())

    assert %Shelf{status: :idle, filled_at: nil, stale_at: nil, failure_count: 0} = shelf
  end

  test "one row per plugin, key and user" do
    user = user_fixture()
    shelf!(user)

    assert_raise Ecto.ConstraintError, fn -> shelf!(user) end
    assert %Shelf{} = shelf!(user, "other")
    assert %Shelf{} = shelf!(user_fixture())
  end

  test "items load in position order and go with their shelf" do
    shelf = shelf!(user_fixture())

    for {title, position} <- [{"Glass Meridian", 1}, {"Ember Tide", 0}] do
      Repo.insert!(%ShelfItem{
        shelf_id: shelf.id,
        position: position,
        media_type: :movie,
        provider: :tmdb,
        provider_id: 100 + position,
        title: title
      })
    end

    assert ["Ember Tide", "Glass Meridian"] ==
             shelf |> Repo.preload(:items) |> Map.fetch!(:items) |> Enum.map(& &1.title)

    Repo.delete!(shelf)
    assert Repo.aggregate(ShelfItem, :count) == 0
  end

  test "deleting a user removes their shelves and dismissals" do
    user = user_fixture()
    shelf!(user)

    Repo.insert!(%ShelfDismissal{
      plugin_slug: "shelfy",
      shelf_key: "picks",
      user_id: user.id,
      media_type: :movie,
      provider: :tmdb,
      provider_id: 7
    })

    {:ok, _} = Accounts.delete_user(user)

    assert Repo.aggregate(Shelf, :count) == 0
    assert Repo.aggregate(ShelfDismissal, :count) == 0
  end

  test "the bookkeeping changeset caps the error text" do
    changeset = Shelf.changeset(shelf!(user_fixture()), %{last_error: String.duplicate("x", 501)})

    refute changeset.valid?
  end
end
