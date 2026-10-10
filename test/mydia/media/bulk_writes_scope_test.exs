defmodule Mydia.Media.BulkWritesScopeTest do
  @moduledoc """
  The bulk media writes honour the caller's access restrictions: ids outside
  the scope are skipped, not modified, and the returned count only covers the
  items the caller can see.
  """
  use Mydia.DataCase, async: true

  import Ecto.Query
  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  defp categorized(attrs, category) do
    item = media_item_fixture(attrs)

    Repo.update_all(from(m in MediaItem, where: m.id == ^item.id),
      set: [category: category]
    )

    Repo.get!(MediaItem, item.id)
  end

  setup do
    scope = %Scope{user: nil, allowed_categories: ["cartoon_movie"]}
    visible = categorized(%{title: "Lantern Harbor", monitored: true}, "cartoon_movie")
    hidden = categorized(%{title: "Ember Tide", monitored: true}, "movie")

    %{scope: scope, visible: visible, hidden: hidden}
  end

  defp monitored?(item), do: Repo.get!(MediaItem, item.id).monitored

  test "update_media_items_monitored skips items outside the scope", ctx do
    assert {:ok, 1} =
             Media.update_media_items_monitored(
               ctx.scope,
               [ctx.visible.id, ctx.hidden.id],
               false
             )

    refute monitored?(ctx.visible)
    assert monitored?(ctx.hidden)
  end

  test "update_media_items_batch skips items outside the scope", ctx do
    assert {:ok, 1} =
             Media.update_media_items_batch(
               ctx.scope,
               [ctx.visible.id, ctx.hidden.id],
               %{monitored: false}
             )

    refute monitored?(ctx.visible)
    assert monitored?(ctx.hidden)
  end

  test "delete_media_items skips items outside the scope", ctx do
    assert {:ok, 1, _removal} =
             Media.delete_media_items(ctx.scope, [ctx.visible.id, ctx.hidden.id])

    refute Repo.get(MediaItem, ctx.visible.id)
    assert Repo.get(MediaItem, ctx.hidden.id)
  end

  test "an unrestricted scope still reaches every item", ctx do
    assert {:ok, 2} =
             Media.update_media_items_monitored(
               Scope.unrestricted(),
               [ctx.visible.id, ctx.hidden.id],
               false
             )
  end

  describe "update_media_items_batch with :monitored" do
    test "an unrecognised value returns an error and changes nothing", ctx do
      assert {:error, :invalid_monitored} =
               Media.update_media_items_batch(
                 Scope.unrestricted(),
                 [ctx.visible.id, ctx.hidden.id],
                 %{monitored: "on"}
               )

      assert monitored?(ctx.visible)
      assert monitored?(ctx.hidden)
    end

    test "the string forms the batch form posts are accepted", ctx do
      assert {:ok, 1} =
               Media.update_media_items_batch(
                 Scope.unrestricted(),
                 [ctx.visible.id],
                 %{monitored: "false"}
               )

      refute monitored?(ctx.visible)
    end
  end
end
