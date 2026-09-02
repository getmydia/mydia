defmodule Mydia.Library.TrashQueriesTest do
  @moduledoc """
  Read helpers behind /admin/config/trash. The counts drive the filter chips
  and the summary drives the header, so both have to agree with the list.
  """
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Repo

  setup %{tmp_dir: tmp_dir} do
    on_exit(fn -> Application.delete_env(:mydia, :trash_dir) end)

    root = Path.join(tmp_dir, "lib")
    File.mkdir_p!(root)
    library_path = library_path_fixture(%{path: root, type: "movies"})

    %{root: root, library_path: library_path}
  end

  defp trashed(root, library_path, name, reason, size) do
    File.write!(Path.join(root, name), String.duplicate("x", size))

    {:ok, media_file} =
      Library.create_scanned_media_file(%{
        relative_path: name,
        library_path_id: library_path.id,
        media_item_id: media_item_fixture(%{type: "movie"}).id,
        size: size
      })

    {:ok, trashed} =
      Library.trash_media_file(Repo.preload(media_file, :library_path), reason: reason)

    trashed
  end

  @tag :tmp_dir
  test "lists only trashed files, newest first", ctx do
    live_name = "still-here.mkv"
    File.write!(Path.join(ctx.root, live_name), "x")

    {:ok, _live} =
      Library.create_scanned_media_file(%{
        relative_path: live_name,
        library_path_id: ctx.library_path.id,
        media_item_id: media_item_fixture(%{type: "movie"}).id,
        size: 1
      })

    a = trashed(ctx.root, ctx.library_path, "a.mkv", :missing, 10)
    b = trashed(ctx.root, ctx.library_path, "b.mkv", :pruned, 20)

    ids = Library.list_trashed_media_files([]) |> Enum.map(& &1.id)

    assert length(ids) == 2
    assert a.id in ids
    assert b.id in ids
  end

  @tag :tmp_dir
  test "filters by reason", ctx do
    _a = trashed(ctx.root, ctx.library_path, "a.mkv", :missing, 10)
    b = trashed(ctx.root, ctx.library_path, "b.mkv", :pruned, 20)

    assert [only] = Library.list_trashed_media_files(reason: :pruned)
    assert only.id == b.id
  end

  @tag :tmp_dir
  test "paginates", ctx do
    for n <- 1..5, do: trashed(ctx.root, ctx.library_path, "f#{n}.mkv", :missing, n)

    assert length(Library.list_trashed_media_files(limit: 2)) == 2
    assert length(Library.list_trashed_media_files(limit: 2, offset: 4)) == 1
  end

  @tag :tmp_dir
  test "counts per reason, including unknown", ctx do
    _a = trashed(ctx.root, ctx.library_path, "a.mkv", :missing, 10)
    _b = trashed(ctx.root, ctx.library_path, "b.mkv", :missing, 10)
    _c = trashed(ctx.root, ctx.library_path, "c.mkv", :pruned, 10)
    _d = trashed(ctx.root, ctx.library_path, "d.mkv", nil, 10)

    counts = Library.count_trashed_media_files()

    assert counts[:missing] == 2
    assert counts[:pruned] == 1
    assert counts[nil] == 1
  end

  @tag :tmp_dir
  test "summary sums count and bytes of trashed rows only", ctx do
    _a = trashed(ctx.root, ctx.library_path, "a.mkv", :missing, 10)
    _b = trashed(ctx.root, ctx.library_path, "b.mkv", :pruned, 32)

    assert %{count: 2, bytes: 42} = Library.trashed_summary()
  end

  # `sum/1` hands back a Decimal on PostgreSQL and an integer on SQLite, and
  # the page runs the byte total through arithmetic that raises on a Decimal.
  # Asserting the type states the requirement on both adapters; the equality
  # above only catches it on the one CI job that runs Postgres.
  @tag :tmp_dir
  test "summary bytes are an integer on either adapter", ctx do
    _a = trashed(ctx.root, ctx.library_path, "a.mkv", :missing, 10)

    assert is_integer(Library.trashed_summary().bytes)
  end

  @tag :tmp_dir
  test "summary bytes are zero, not nil, with nothing trashed", _ctx do
    assert %{count: 0, bytes: 0} = Library.trashed_summary()
  end

  # Same defect in the sibling aggregate, which used a SQL cast to :integer
  # instead. That raises "integer out of range" on PostgreSQL past 2.1 GB,
  # so the size here is deliberately over the 4-byte ceiling.
  @tag :tmp_dir
  test "total_storage_bytes/0 survives a library larger than a 4-byte integer", ctx do
    File.write!(Path.join(ctx.root, "huge.mkv"), "x")

    {:ok, _} =
      Library.create_scanned_media_file(%{
        relative_path: "huge.mkv",
        library_path_id: ctx.library_path.id,
        media_item_id: media_item_fixture(%{type: "movie"}).id,
        size: 3_000_000_000
      })

    assert Library.total_storage_bytes() == 3_000_000_000
  end

  @tag :tmp_dir
  test "purge_media_file/1 removes the row and the bytes", ctx do
    file = trashed(ctx.root, ctx.library_path, "gone.mkv", :pruned, 10)
    trash_path = file.metadata.extra["trashed_path"]

    assert File.exists?(trash_path)
    assert :ok = Library.purge_media_file(file)

    refute File.exists?(trash_path)
    assert is_nil(Repo.get(Mydia.Library.MediaFile, file.id))
  end

  @tag :tmp_dir
  test "purging a missing-state row touches no library file", ctx do
    name = "reappeared.mkv"
    File.write!(Path.join(ctx.root, name), "x")

    {:ok, media_file} =
      Library.create_scanned_media_file(%{
        relative_path: name,
        library_path_id: ctx.library_path.id,
        media_item_id: media_item_fixture(%{type: "movie"}).id,
        size: 1
      })

    File.rm!(Path.join(ctx.root, name))

    {:ok, trashed} =
      Library.trash_media_file(Repo.preload(media_file, :library_path), reason: :missing)

    # The mount comes back and the file is there again.
    File.write!(Path.join(ctx.root, name), "x")

    assert :ok = Library.purge_media_file(trashed)
    assert File.exists?(Path.join(ctx.root, name))
  end

  # Two tabs on the trash page. One restores a row while the other still holds
  # the struct it loaded before that, with trashed_at set. Repo.delete/1 would
  # match on the primary key alone and drop the row of a file now sitting live
  # in the library.
  @tag :tmp_dir
  test "purge_media_file/1 refuses a row restored since it was loaded", ctx do
    stale = trashed(ctx.root, ctx.library_path, "raced.mkv", :manual, 10)

    {:ok, restored} = Library.restore_media_file(stale)
    assert is_nil(restored.trashed_at)

    assert {:error, :not_trashed} = Library.purge_media_file(stale)
    assert Repo.get(Mydia.Library.MediaFile, stale.id)
  end
end
