defmodule MydiaWeb.LibrarySchema.MediaItemChangesTest do
  @moduledoc """
  The revision-paged change feed a polling consumer drives.

  Every assertion here is about what a consumer observes across a cursor: which
  items arrive, in which order, and that an item's `updatedAt` is the marker's
  `changedAt`. The cursor is the marker's database revision, so a page boundary
  is never a wall clock.
  """

  use MydiaWeb.ConnCase

  alias Mydia.LibraryApi.Cursor
  alias Mydia.LibraryApi.MediaItemRevision
  alias Mydia.LibraryApi.Principal
  alias Mydia.LibraryApi.RevisionCursor
  alias Mydia.Media
  alias Mydia.Repo
  alias MydiaWeb.LibrarySchema.Resolvers.MediaItemChanges

  @admin %Principal{role: "admin", source: :api_key}

  @changes """
  query Changes($first: Int, $after: String) {
    mediaItemChanges(first: $first, after: $after) {
      edges {
        cursor
        node {
          mediaItemId
          deleted
          changedAt
          mediaItem { id title updatedAt status { state } }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  defp run(query, variables) do
    Absinthe.run(query, MydiaWeb.LibrarySchema,
      variables: variables,
      context: %{principal: @admin}
    )
  end

  defp changes(variables) do
    {:ok, %{data: %{"mediaItemChanges" => connection}}} = run(@changes, variables)
    connection
  end

  defp edge_ids(%{"edges" => edges}), do: Enum.map(edges, & &1["node"]["mediaItemId"])
  defp end_cursor(%{"pageInfo" => %{"endCursor" => cursor}}), do: cursor

  defp marker!(id), do: Repo.get_by!(MediaItemRevision, media_item_id: id)

  defp timestamp(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end

  test "pages forward by revision, never repeating an item" do
    for n <- 1..3, do: insert(:media_item, type: "movie", title: "Movie #{n}")

    first = changes(%{"first" => 2})
    assert length(first["edges"]) == 2
    assert first["pageInfo"]["hasNextPage"] == true

    second = changes(%{"first" => 2, "after" => end_cursor(first)})
    assert length(second["edges"]) == 1
    assert second["pageInfo"]["hasNextPage"] == false

    assert MapSet.disjoint?(MapSet.new(edge_ids(first)), MapSet.new(edge_ids(second)))
  end

  test "edge cursors and endCursor are the markers' revisions, never a timestamp" do
    for _ <- 1..2, do: insert(:media_item, type: "movie")

    connection = changes(%{"first" => 50})

    for edge <- connection["edges"] do
      id = edge["node"]["mediaItemId"]
      assert RevisionCursor.decode(edge["cursor"]) == {:ok, marker!(id).revision}
    end

    last = List.last(connection["edges"])

    assert RevisionCursor.decode(end_cursor(connection)) ==
             {:ok, marker!(last["node"]["mediaItemId"]).revision}
  end

  test "an empty page repeats the cursor it was given" do
    insert(:media_item)

    cursor = end_cursor(changes(%{"first" => 200}))
    assert is_binary(cursor)

    assert changes(%{"first" => 200, "after" => cursor}) ==
             %{"edges" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => cursor}}
  end

  test "a child-only change arrives after the snapshot with an advanced aggregate updatedAt" do
    show = insert(:tv_show, title: "Severance")
    episode = insert(:episode, media_item: show, monitored: true)

    snapshot = changes(%{"first" => 50})
    assert edge_ids(snapshot) == [show.id]
    [%{"node" => before_node}] = snapshot["edges"]

    {:ok, _} = Media.update_episode(episode, %{monitored: false})

    page = changes(%{"first" => 50, "after" => end_cursor(snapshot)})

    assert [%{"node" => node}] = page["edges"]
    assert node["mediaItemId"] == show.id
    assert node["deleted"] == false
    assert node["changedAt"] == node["mediaItem"]["updatedAt"]

    assert DateTime.compare(
             timestamp(node["mediaItem"]["updatedAt"]),
             timestamp(before_node["mediaItem"]["updatedAt"])
           ) == :gt
  end

  test "a deleted item arrives as a tombstone with no mediaItem" do
    show = insert(:tv_show, title: "Severance")
    insert(:episode, media_item: show)

    snapshot = changes(%{"first" => 50})
    assert edge_ids(snapshot) == [show.id]

    {:ok, _deleted, _files_not_deleted} = Media.delete_media_item(show)

    page = changes(%{"first" => 50, "after" => end_cursor(snapshot)})

    assert [%{"node" => node}] = page["edges"]
    assert node["mediaItemId"] == show.id
    assert node["deleted"] == true
    assert node["mediaItem"] == nil
  end

  test "an item that vanishes between the page query and hydration is a tombstone, not a dropped edge" do
    show = insert(:tv_show, title: "Severance")
    boundary = marker!(show.id)

    loader = fn _ids ->
      {:ok, _deleted, _files_not_deleted} = Media.delete_media_item(show)
      %{}
    end

    assert {:ok, connection} = MediaItemChanges.resolve(%{first: 50}, load_items: loader)

    assert [%{node: node, cursor: cursor}] = connection.edges
    assert node.media_item_id == show.id
    assert node.deleted == true
    assert node.media_item == nil
    assert cursor == RevisionCursor.encode(boundary.revision)
    assert connection.page_info.end_cursor == RevisionCursor.encode(boundary.revision)
  end

  test "refuses first below 1 and above the cap" do
    for first <- [0, -5, 201] do
      assert {:ok, %{errors: errors}} = run(@changes, %{"first" => first})
      assert Enum.any?(errors, &(&1.extensions[:code] == "INVALID_INPUT"))
    end
  end

  test "accepts the cap itself" do
    insert(:media_item, type: "movie", title: "Only one")

    assert length(changes(%{"first" => 200})["edges"]) == 1
  end

  test "an invalid cursor is an error rather than ignored" do
    assert {:ok, %{errors: errors}} = run(@changes, %{"first" => 2, "after" => "garbage"})
    assert Enum.any?(errors, &(&1.extensions[:code] == "INVALID_INPUT"))
  end

  test "a cursor from the retired timestamp feed is refused so the consumer resyncs" do
    old = Cursor.encode(~U[2026-09-11 00:00:00Z], Ecto.UUID.generate())

    assert {:ok, %{errors: errors}} = run(@changes, %{"first" => 2, "after" => old})
    assert Enum.any?(errors, &(&1.extensions[:code] == "INVALID_INPUT"))
  end
end
