defmodule Mydia.Accounts.RestrictionShelfResetTest do
  # async: false: the plugin registry the shelf helpers use is app-wide.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.ShelfHelpers

  alias Mydia.Accounts
  alias Mydia.Plugins.Shelf
  alias Mydia.Plugins.ShelfItem

  setup do
    register_shelf_plugin!()
    user = user_fixture(%{role: "user"})
    far = DateTime.add(DateTime.utc_now(), 80_000)
    shelf = shelf_fixture(user, filled_at: DateTime.utc_now(), stale_at: far)
    shelf_item_fixture(shelf)

    other_shelf = shelf_fixture(user_fixture(), filled_at: DateTime.utc_now(), stale_at: far)
    shelf_item_fixture(other_shelf, %{provider_id: 2})

    {:ok, user: user, shelf: shelf, other_shelf: other_shelf}
  end

  defp items(shelf), do: Repo.all(from i in ShelfItem, where: i.shelf_id == ^shelf.id)

  test "creating a restriction clears the user's stored picks", ctx do
    assert {:ok, _} = Accounts.upsert_access_restriction(ctx.user, %{max_content_age: 12})

    assert items(ctx.shelf) == []
    assert Repo.get!(Shelf, ctx.shelf.id).stale_at == nil
  end

  test "changing a restriction clears them again", ctx do
    {:ok, _} = Accounts.upsert_access_restriction(ctx.user, %{max_content_age: 12})
    shelf_item_fixture(ctx.shelf, %{provider_id: 9})

    assert {:ok, _} = Accounts.upsert_access_restriction(ctx.user, %{max_content_age: 16})
    assert items(ctx.shelf) == []
  end

  test "removing a restriction clears them, so the wider rules apply on the next fill", ctx do
    {:ok, _} = Accounts.upsert_access_restriction(ctx.user, %{max_content_age: 12})
    shelf_item_fixture(ctx.shelf, %{provider_id: 9})

    assert :ok = Accounts.clear_access_restriction(ctx.user)
    assert items(ctx.shelf) == []
  end

  test "clearing when there is no restriction leaves the picks alone", ctx do
    assert :ok = Accounts.clear_access_restriction(ctx.user)
    assert [%ShelfItem{}] = items(ctx.shelf)
  end

  test "a rejected restriction leaves the picks alone", ctx do
    assert {:error, :admin} =
             Accounts.upsert_access_restriction(%{ctx.user | role: "admin"}, %{
               max_content_age: 12
             })

    assert [%ShelfItem{}] = items(ctx.shelf)
  end

  test "another user's shelf is untouched", ctx do
    {:ok, _} = Accounts.upsert_access_restriction(ctx.user, %{max_content_age: 12})

    assert [%ShelfItem{}] = items(ctx.other_shelf)
    assert %Shelf{stale_at: %DateTime{}} = Repo.get!(Shelf, ctx.other_shelf.id)
  end
end
