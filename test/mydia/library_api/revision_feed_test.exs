defmodule Mydia.LibraryApi.RevisionFeedTest do
  @moduledoc """
  The behavior of the latest-state revision feed.

  `RevisionFeed` reads the rows the database triggers own: one per media item
  ever observed, tombstones included, ordered by the database-generated
  `revision`. Every assertion here is about what a polling consumer observes,
  not about how the rows got there.
  """

  use Mydia.DataCase, async: false

  alias Mydia.LibraryApi.MediaItemRevision
  alias Mydia.LibraryApi.RevisionFeed
  alias Mydia.Repo

  defp marker!(media_item_id), do: Repo.get_by!(MediaItemRevision, media_item_id: media_item_id)

  defp marker_count(media_item_id) do
    Repo.aggregate(from(r in MediaItemRevision, where: r.media_item_id == ^media_item_id), :count)
  end

  defp feed(item), do: Enum.filter(RevisionFeed.list(limit: 200), &(&1.media_item_id == item.id))

  test "lists live markers in ascending revision order and stops at the limit" do
    items = for _ <- 1..3, do: insert(:media_item)

    rows = RevisionFeed.list(limit: 10)

    assert Enum.map(rows, & &1.media_item_id) == Enum.map(items, & &1.id)
    assert Enum.map(rows, & &1.revision) == Enum.sort(Enum.map(rows, & &1.revision))
    assert [%MediaItemRevision{} = first] = RevisionFeed.list(limit: 1)
    assert first.revision == hd(rows).revision
  end

  test "resumes strictly after the boundary revision" do
    items = for _ <- 1..3, do: insert(:media_item)

    assert [%MediaItemRevision{} = boundary] = RevisionFeed.list(limit: 1)
    assert boundary.media_item_id == hd(items).id

    resumed = RevisionFeed.list(limit: 200, after: boundary.revision)

    assert Enum.map(resumed, & &1.media_item_id) == Enum.map(tl(items), & &1.id)

    assert Enum.all?(resumed, fn row ->
             row.revision > boundary.revision
           end)
  end

  test "coalesces repeat changes to one row per media item, newest revision" do
    item = insert(:media_item)
    listed = marker!(item.id)

    {:ok, _} = Mydia.Media.update_media_item(item, %{title: "First change"})
    {:ok, _} = Mydia.Media.update_media_item(item, %{title: "Second change"})

    assert [%MediaItemRevision{revision: revision, deleted: false}] = feed(item)
    assert revision > listed.revision
    assert marker_count(item.id) == 1
  end

  test "a deletion keeps its tombstone in the feed, ordered after the live marker" do
    item = insert(:media_item)
    listed = marker!(item.id)

    {:ok, _deleted, _files_not_deleted} = Mydia.Media.delete_media_item(item)

    assert [%MediaItemRevision{revision: revision, deleted: true}] = feed(item)
    assert revision > listed.revision
    assert marker_count(item.id) == 1
  end

  test "changed_at_by_ids returns marker timestamps for live ids only" do
    live = insert(:media_item)
    removed = insert(:media_item)
    {:ok, _deleted, _files_not_deleted} = Mydia.Media.delete_media_item(removed)

    assert RevisionFeed.changed_at_by_ids([]) == %{}

    assert RevisionFeed.changed_at_by_ids([live.id, removed.id]) == %{
             live.id => marker!(live.id).changed_at
           }

    assert RevisionFeed.changed_at_by_ids([removed.id]) == %{}
    assert RevisionFeed.changed_at_by_ids([Ecto.UUID.generate()]) == %{}
  end

  test "changed_at! returns the live marker timestamp and raises when the invariant is broken" do
    item = insert(:media_item)
    assert RevisionFeed.changed_at!(item.id) == marker!(item.id).changed_at

    assert_raise Ecto.NoResultsError, fn ->
      RevisionFeed.changed_at!(Ecto.UUID.generate())
    end

    removed = insert(:media_item)
    {:ok, _deleted, _files_not_deleted} = Mydia.Media.delete_media_item(removed)

    assert_raise Ecto.NoResultsError, fn -> RevisionFeed.changed_at!(removed.id) end
  end

  test "mark_live advances a live marker once per unique id" do
    item = insert(:media_item)
    listed = marker!(item.id)

    assert RevisionFeed.mark_live([]) == :ok
    assert marker!(item.id).revision == listed.revision

    assert RevisionFeed.mark_live([item.id, item.id]) == :ok

    marked = marker!(item.id)
    assert marked.revision > listed.revision
    refute marked.deleted
    assert marker_count(item.id) == 1
  end

  test "mark_live neither resurrects a tombstone nor invents a marker" do
    removed = insert(:media_item)
    {:ok, _deleted, _files_not_deleted} = Mydia.Media.delete_media_item(removed)
    tombstone = marker!(removed.id)
    unknown = Ecto.UUID.generate()

    assert RevisionFeed.mark_live([removed.id, unknown]) == :ok

    assert marker!(removed.id) == tombstone
    assert Repo.get_by(MediaItemRevision, media_item_id: unknown) == nil
  end

  test "mark_live cannot move a marker whose stored revision is already ahead" do
    # Simulate a stale allocation: the stored marker sits ahead of the next
    # revision the clock path can allocate. The greater-revision guard must leave
    # its revision and deleted flag alone, because a marker moved backwards is a
    # permanent consumer miss.
    live = insert(:media_item)
    ahead = marker!(live.id).revision + 1_000_000
    store_marker_ahead!(live.id, ahead)

    assert RevisionFeed.mark_live([live.id]) == :ok

    marked = marker!(live.id)
    assert marked.revision >= ahead
    refute marked.deleted
    assert marker_count(live.id) == 1

    # PostgreSQL identity values are handed out outside commit order, so the
    # clock sweep's revision can arrive below the committed marker's and only the
    # guard keeps it from moving backwards. SQLite's AUTOINCREMENT allocates
    # inside the write lock, in commit order, so its guard is inert and a
    # tombstone on a still-present item is legitimately revived by the next
    # allocation. The flag case is therefore PostgreSQL-only.
    if Mydia.DB.postgres?() do
      tombstoned = insert(:media_item)
      ahead = marker!(tombstoned.id).revision + 1_000_000
      store_marker_ahead!(tombstoned.id, ahead, true)

      assert RevisionFeed.mark_live([tombstoned.id]) == :ok

      marked = marker!(tombstoned.id)
      assert marked.revision == ahead
      assert marked.deleted
    end
  end

  # Writes the marker ahead of what the clock path can allocate next. SQLite's
  # AUTOINCREMENT watermark tracks the largest rowid ever used, and an UPDATE
  # that raises a rowid raises that watermark too, so it is rewound after the
  # write; PostgreSQL keeps its sequence behind an identity column set directly,
  # so it needs nothing.
  defp store_marker_ahead!(media_item_id, revision, deleted \\ false) do
    Repo.update_all(
      from(r in MediaItemRevision, where: r.media_item_id == ^media_item_id),
      set: [revision: revision, deleted: deleted]
    )

    unless Mydia.DB.postgres?() do
      Repo.query!(
        "UPDATE sqlite_sequence SET seq = ? WHERE name = 'media_item_revisions'",
        [revision - 1]
      )
    end
  end
end
