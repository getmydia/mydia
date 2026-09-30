defmodule Mydia.Plugins.JournalTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Collections
  alias Mydia.Plugins.Journal
  alias Mydia.Plugins.PageWrites

  setup do
    user = user_fixture()
    {:ok, c} = Collections.create_collection(user, %{name: "Shelf", type: "manual"})
    items = for t <- ["Harbor of Glass", "The Tin Orchard"], do: media_item_fixture(%{title: t})
    {:ok, user: user, c: c, items: items}
  end

  defp run(user, op, args, batch) do
    {:ok, result, inverse} = PageWrites.execute(op, args, user, "plugin:helper")
    {:ok, entry} = Journal.record("helper", user.id, op, args, result, inverse, "desc", batch)
    entry
  end

  test "noop writes are not journaled", %{user: user, c: c, items: [a | _]} do
    args = %{"id" => c.id, "media_item_ids" => [a.id]}
    run(user, "collection_add_items", args, "b1")
    {:ok, result, :noop} = PageWrites.execute("collection_add_items", args, user, "plugin:helper")

    assert {:ok, nil} =
             Journal.record(
               "helper",
               user.id,
               "collection_add_items",
               args,
               result,
               :noop,
               "d",
               "b2"
             )

    assert length(Journal.list("helper", user.id)) == 1
  end

  test "undo_entry reverts and marks undone; a second undo is refused", %{
    user: user,
    c: c,
    items: [a | _]
  } do
    entry = run(user, "collection_add_items", %{"id" => c.id, "media_item_ids" => [a.id]}, "b1")
    assert {:ok, %{status: "undone"}} = Journal.undo_entry(user, entry.id)
    assert {:error, :already_undone} = Journal.undo_entry(user, entry.id)
  end

  test "undo_batch reverts newest first", %{user: user, items: [a, b]} do
    create = run(user, "collection_create", %{"name" => "New", "type" => "manual"}, "b9")
    id = create.result["id"]
    run(user, "collection_add_items", %{"id" => id, "media_item_ids" => [a.id, b.id]}, "b9")

    assert {:ok, entries} = Journal.undo_batch(user, "helper", "b9")
    assert length(entries) == 2
    assert Enum.all?(entries, &(&1.status == "undone"))
    assert Collections.get_collection(user, id) == nil
  end

  test "conflict is recorded without writing", %{user: user, c: c, items: [a | _]} do
    entry = run(user, "collection_add_items", %{"id" => c.id, "media_item_ids" => [a.id]}, "b1")
    {:ok, _} = Collections.remove_item(c, a.id)

    assert {:error, :conflict} = Journal.undo_entry(user, entry.id)
    assert [%{status: "conflict"}] = Journal.list("helper", user.id)
  end

  test "another user cannot undo", %{user: user, c: c, items: [a | _]} do
    entry = run(user, "collection_add_items", %{"id" => c.id, "media_item_ids" => [a.id]}, "b1")
    assert {:error, :not_found} = Journal.undo_entry(user_fixture(), entry.id)
  end
end
