defmodule Mydia.Library.TrashAuditTest do
  @moduledoc """
  Bytes in .mydia-trash that nothing will ever purge.

  The obvious rule, "a container whose id has no media_files row", is wrong
  twice over. It misses a restore that hit an occupied library path (the row
  is alive and still points at the trash copy, and nothing purges it), and it
  races an in-flight trash, which moves bytes before it stamps trashed_at.
  """
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Library.TrashStore
  alias Mydia.Repo

  setup %{tmp_dir: tmp_dir} do
    trash_root = Path.join(tmp_dir, "trash")
    File.mkdir_p!(trash_root)
    Application.put_env(:mydia, :trash_dir, trash_root)
    on_exit(fn -> Application.delete_env(:mydia, :trash_dir) end)

    root = Path.join(tmp_dir, "lib")
    File.mkdir_p!(root)
    library_path = library_path_fixture(%{path: root, type: "movies"})

    %{root: root, trash_root: trash_root, library_path: library_path}
  end

  defp scanned(ctx, name, size) do
    File.write!(Path.join(ctx.root, name), String.duplicate("x", size))

    {:ok, media_file} =
      Library.create_scanned_media_file(%{
        relative_path: name,
        library_path_id: ctx.library_path.id,
        media_item_id: media_item_fixture(%{type: "movie"}).id,
        size: size
      })

    Repo.preload(media_file, :library_path)
  end

  # Containers are skipped while they might belong to a trash still running.
  # Backdate so the test is not fighting its own guard.
  defp backdate(path) do
    old = System.os_time(:second) - 7200
    File.touch!(path, old)
  end

  @tag :tmp_dir
  test "a properly trashed file is not reported", ctx do
    file = scanned(ctx, "tracked.mkv", 10)
    {:ok, trashed} = Library.trash_media_file(file, reason: :pruned)
    backdate(Path.dirname(trashed.metadata.extra["trashed_path"]))

    assert %{retained: [], orphaned: []} = TrashStore.audit()
  end

  @tag :tmp_dir
  test "a retained copy after an occupied restore is reported", ctx do
    file = scanned(ctx, "retained.mkv", 10)
    {:ok, trashed} = Library.trash_media_file(file, reason: :manual)

    # Someone else takes the library path back.
    File.write!(Path.join(ctx.root, "retained.mkv"), "different")
    {:ok, restored, :trash_copy_retained} = Library.restore_media_file(trashed)

    container = Path.dirname(restored.metadata.extra["trashed_path"])
    backdate(container)

    assert %{retained: [entry], orphaned: []} = TrashStore.audit()
    assert entry.path == container
    assert entry.media_file_id == file.id
    assert entry.bytes == 10
  end

  @tag :tmp_dir
  test "a container with no row at all is orphaned", ctx do
    container = Path.join(ctx.trash_root, Ecto.UUID.generate())
    File.mkdir_p!(container)
    File.write!(Path.join(container, "debris.mkv"), String.duplicate("x", 25))
    backdate(container)

    assert %{retained: [], orphaned: [entry]} = TrashStore.audit()
    assert entry.path == container
    assert is_nil(entry.media_file_id)
    assert entry.bytes == 25
  end

  @tag :tmp_dir
  test "a trash root that does not exist yet returns empty", ctx do
    File.rm_rf!(ctx.trash_root)

    assert %{retained: [], orphaned: []} = TrashStore.audit()
  end

  @tag :tmp_dir
  test "sweep removes what audit returned and leaves tracked containers alone", ctx do
    keep = scanned(ctx, "keep.mkv", 10)
    {:ok, kept} = Library.trash_media_file(keep, reason: :pruned)
    kept_container = Path.dirname(kept.metadata.extra["trashed_path"])
    backdate(kept_container)

    container = Path.join(ctx.trash_root, Ecto.UUID.generate())
    File.mkdir_p!(container)
    File.write!(Path.join(container, "debris.mkv"), String.duplicate("x", 25))
    backdate(container)

    audit = TrashStore.audit()
    assert %{swept: 1, bytes: 25, skipped: 0} = TrashStore.sweep(audit.orphaned)

    refute File.exists?(container)
    assert File.exists?(kept_container)
  end

  @tag :tmp_dir
  test "sweep skips a container young enough to be an in-flight trash", ctx do
    container = Path.join(ctx.trash_root, Ecto.UUID.generate())
    File.mkdir_p!(container)
    File.write!(Path.join(container, "in-flight.mkv"), "x")
    # Deliberately not backdated.

    entry = %{path: container, media_file_id: nil, bytes: 1}

    assert %{swept: 0, skipped: 1} = TrashStore.sweep([entry])
    assert File.exists?(container)
  end
end
