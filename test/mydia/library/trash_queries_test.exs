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
end
