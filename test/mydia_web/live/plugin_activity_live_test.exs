defmodule MydiaWeb.PluginActivityLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Collections
  alias Mydia.Plugins.Journal
  alias Mydia.Plugins.PageWrites

  @slug "helper"

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    item = Mydia.MediaFixtures.media_item_fixture(%{title: "Harbor of Glass"})
    {:ok, collection} = Collections.create_collection(user, %{name: "Shelf", type: "manual"})
    %{conn: conn, user: user, item: item, collection: collection}
  end

  defp write!(user, collection, item, batch) do
    args = %{"id" => collection.id, "media_item_ids" => [item.id]}

    {:ok, result, inverse} =
      PageWrites.execute("collection_add_items", args, user, "plugin:#{@slug}")

    {:ok, entry} =
      Journal.record(
        @slug,
        user.id,
        "collection_add_items",
        args,
        result,
        inverse,
        "Add 1 item(s) to \"Shelf\"",
        batch
      )

    entry
  end

  test "shows an empty state", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/plugins/#{@slug}/activity")
    assert has_element?(view, "#journal-empty")
  end

  test "lists the user's writes and undoes one", ctx do
    %{conn: conn, user: user, item: item, collection: collection} = ctx
    entry = write!(user, collection, item, "b1")

    {:ok, view, _} = live(conn, ~p"/plugins/#{@slug}/activity")
    assert has_element?(view, "#journal-#{entry.id}", "Shelf")

    view |> element("#undo-#{entry.id}") |> render_click()

    assert has_element?(view, "#journal-#{entry.id} .badge", "Undone")
    refute has_element?(view, "#undo-#{entry.id}")
    assert Collections.item_ids_in(collection, [item.id]) == MapSet.new()
  end

  test "reports a conflict and leaves the entry marked", ctx do
    %{conn: conn, user: user, item: item, collection: collection} = ctx
    entry = write!(user, collection, item, "b1")
    {:ok, view, _} = live(conn, ~p"/plugins/#{@slug}/activity")

    # The user removes the item themselves after the write.
    {:ok, _} = Collections.remove_item(collection, item.id)

    view |> element("#undo-#{entry.id}") |> render_click()

    assert has_element?(view, "#journal-#{entry.id} .badge", "Changed since")
    assert has_element?(view, "#flash-error", "changed since")
    refute has_element?(view, "#undo-#{entry.id}")
  end

  test "undoes a whole batch", ctx do
    %{conn: conn, user: user, item: item, collection: collection} = ctx
    other = Mydia.MediaFixtures.media_item_fixture(%{title: "The Tin Orchard"})
    e1 = write!(user, collection, item, "b2")
    e2 = write!(user, collection, other, "b2")

    {:ok, view, _} = live(conn, ~p"/plugins/#{@slug}/activity")
    view |> element("#undo-batch-b2") |> render_click()

    assert has_element?(view, "#journal-#{e1.id} .badge", "Undone")
    assert has_element?(view, "#journal-#{e2.id} .badge", "Undone")
    assert Collections.item_ids_in(collection, [item.id, other.id]) == MapSet.new()
  end

  test "never shows or undoes another user's entries", ctx do
    %{conn: conn, item: item} = ctx
    owner = Mydia.AccountsFixtures.user_fixture()
    {:ok, theirs} = Collections.create_collection(owner, %{name: "Theirs", type: "manual"})
    entry = write!(owner, theirs, item, "b3")

    {:ok, view, _} = live(conn, ~p"/plugins/#{@slug}/activity")
    refute has_element?(view, "#journal-#{entry.id}")

    render_click(view, "undo_entry", %{"id" => entry.id})

    assert Collections.item_ids_in(theirs, [item.id]) == MapSet.new([item.id])
    assert Journal.list(@slug, owner.id) |> hd() |> Map.fetch!(:status) == "applied"
  end
end
