defmodule Mydia.LibraryApi.RevisionFeedTest do
  @moduledoc """
  The behavior of the latest-state revision feed.

  `RevisionFeed` reads the rows the database triggers own: one per media item
  ever observed, tombstones included, ordered by the database-generated
  `revision`. Every assertion here is about what a polling consumer observes,
  not about how the rows got there.
  """

  use Mydia.DataCase, async: false

  alias Mydia.Accounts.Scope
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

    {:ok, _} = Mydia.Media.update_media_item(Scope.unrestricted(), item, %{title: "First change"})

    {:ok, _} =
      Mydia.Media.update_media_item(Scope.unrestricted(), item, %{title: "Second change"})

    assert [%MediaItemRevision{revision: revision, deleted: false}] = feed(item)
    assert revision > listed.revision
    assert marker_count(item.id) == 1
  end

  test "a deletion keeps its tombstone in the feed, ordered after the live marker" do
    item = insert(:media_item)
    listed = marker!(item.id)

    {:ok, _deleted, _files_not_deleted} =
      Mydia.Media.delete_media_item(Scope.unrestricted(), item)

    assert [%MediaItemRevision{revision: revision, deleted: true}] = feed(item)
    assert revision > listed.revision
    assert marker_count(item.id) == 1
  end

  test "changed_at_by_ids returns marker timestamps for live ids only" do
    live = insert(:media_item)
    removed = insert(:media_item)

    {:ok, _deleted, _files_not_deleted} =
      Mydia.Media.delete_media_item(Scope.unrestricted(), removed)

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

    {:ok, _deleted, _files_not_deleted} =
      Mydia.Media.delete_media_item(Scope.unrestricted(), removed)

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

    {:ok, _deleted, _files_not_deleted} =
      Mydia.Media.delete_media_item(Scope.unrestricted(), removed)

    tombstone = marker!(removed.id)
    unknown = Ecto.UUID.generate()

    assert RevisionFeed.mark_live([removed.id, unknown]) == :ok

    assert marker!(removed.id) == tombstone
    assert Repo.get_by(MediaItemRevision, media_item_id: unknown) == nil
  end

  test "mark_live advances a still-present item past a stale allocation" do
    # The clock path allocates before the conflict is resolved. On PostgreSQL
    # that value can tie the marker, and the apply function retries with a new
    # identity value, so a still-present item moves forward and a tombstone on
    # a live row is cleared. The parked revision is the next real allocation
    # (or, on SQLite, one step past the watermark), not a synthetic gap, and
    # PostgreSQL's sequence is left where it is.
    Enum.each([false, true], fn deleted ->
      item = insert(:media_item)
      ahead = park_marker!(item.id, deleted)

      assert RevisionFeed.mark_live([item.id]) == :ok

      marked = marker!(item.id)
      assert marked.revision > ahead
      refute marked.deleted
      assert marker_count(item.id) == 1
    end)
  end

  # Parks the marker on a real sequence position rather than a million-step gap.
  #
  # PostgreSQL: the row's revision becomes the next identity value and the
  # sequence is not moved, so `mark_live`'s first `nextval` ties it and only
  # the retry delivers. Rewinding the shared sequence would hand some other
  # test a duplicate revision.
  #
  # SQLite: there is no retry, and AUTOINCREMENT will not allocate a rowid the
  # table still holds. Park one past the watermark and leave that watermark in
  # place, so the next allocation is a minimal gap ahead and the write lands.
  defp park_marker!(media_item_id, deleted) do
    if Mydia.DB.postgres?() do
      park_postgres_marker!(media_item_id, deleted)
    else
      park_sqlite_marker!(media_item_id, deleted)
    end
  end

  defp park_postgres_marker!(media_item_id, deleted) do
    # A concurrent test can consume the peeked value before this update lands.
    # Retry against the new next value rather than holding a primary key the
    # sequence has already handed out. Do not read the sequence again after a
    # successful park: another connection will move it, and `mark_live` still
    # delivers either by tying this revision or by allocating past it.
    Enum.find_value(1..8, fn _attempt ->
      ahead = next_identity_value!()

      try do
        {1, _} =
          Repo.update_all(
            from(r in MediaItemRevision, where: r.media_item_id == ^media_item_id),
            set: [revision: ahead, deleted: deleted]
          )

        ahead
      rescue
        Ecto.ConstraintError -> nil
        Postgrex.Error -> nil
      end
    end) || flunk("could not park the marker on the next identity value")
  end

  defp park_sqlite_marker!(media_item_id, deleted) do
    %{rows: [[seq]]} =
      Repo.query!("SELECT seq FROM sqlite_sequence WHERE name = 'media_item_revisions'")

    ahead = seq + 1

    {1, _} =
      Repo.update_all(
        from(r in MediaItemRevision, where: r.media_item_id == ^media_item_id),
        set: [revision: ahead, deleted: deleted]
      )

    Repo.query!(
      "UPDATE sqlite_sequence SET seq = MAX(seq, ?) WHERE name = 'media_item_revisions'",
      [ahead]
    )

    ahead
  end

  defp next_identity_value! do
    %{rows: [[sequence]]} =
      Repo.query!("SELECT pg_get_serial_sequence('media_item_revisions', 'revision')")

    # The sequence relation exposes last_value and is_called, not its increment.
    # This identity column steps by 1. Reading it does not allocate, and the
    # sequence is not rewound afterwards.
    %{rows: [[last, called]]} =
      Repo.query!("SELECT last_value, is_called FROM #{sequence}")

    if called, do: last + 1, else: last
  end
end
