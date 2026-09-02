defmodule Mydia.Jobs.TrashActionTest do
  @moduledoc """
  Bulk restore and purge run as a job, not in the LiveView. Restoring a few
  hundred files moves bytes, and that work has to survive the operator
  closing the tab.
  """
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Jobs.TrashAction
  alias Mydia.Library
  alias Mydia.Repo

  setup %{tmp_dir: tmp_dir} do
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    trash_root = Path.join(tmp_dir, "trash")
    File.mkdir_p!(trash_root)
    Application.put_env(:mydia, :trash_dir, trash_root)
    on_exit(fn -> Application.delete_env(:mydia, :trash_dir) end)

    root = Path.join(tmp_dir, "lib")
    File.mkdir_p!(root)
    %{root: root, library_path: library_path_fixture(%{path: root, type: "movies"})}
  end

  defp trashed(ctx, name, reason) do
    File.write!(Path.join(ctx.root, name), "x")

    {:ok, media_file} =
      Library.create_scanned_media_file(%{
        relative_path: name,
        library_path_id: ctx.library_path.id,
        media_item_id: media_item_fixture(%{type: "movie"}).id,
        size: 1
      })

    {:ok, t} = Library.trash_media_file(Repo.preload(media_file, :library_path), reason: reason)
    t
  end

  @tag :tmp_dir
  test "restores an explicit id list", ctx do
    a = trashed(ctx, "a.mkv", :missing)
    b = trashed(ctx, "b.mkv", :missing)

    assert :ok =
             perform_job(TrashAction, %{
               "action" => "restore",
               "selection" => %{"type" => "ids", "ids" => [a.id]}
             })

    assert is_nil(Repo.reload(a).trashed_at)
    refute is_nil(Repo.reload(b).trashed_at)
  end

  @tag :tmp_dir
  test "restores everything matching a reason, past the page size", ctx do
    files = for n <- 1..60, do: trashed(ctx, "f#{n}.mkv", :missing)
    other = trashed(ctx, "other.mkv", :pruned)

    assert :ok =
             perform_job(TrashAction, %{
               "action" => "restore",
               "selection" => %{"type" => "all_matching", "reason" => "missing"}
             })

    for f <- files, do: assert(is_nil(Repo.reload(f).trashed_at))
    refute is_nil(Repo.reload(other).trashed_at)
  end

  @tag :tmp_dir
  test "purges an explicit id list", ctx do
    a = trashed(ctx, "a.mkv", :pruned)

    assert :ok =
             perform_job(TrashAction, %{
               "action" => "purge",
               "selection" => %{"type" => "ids", "ids" => [a.id]}
             })

    assert is_nil(Repo.get(Mydia.Library.MediaFile, a.id))
  end

  @tag :tmp_dir
  test "a retained copy still processes the rest", ctx do
    a = trashed(ctx, "a.mkv", :missing)
    b = trashed(ctx, "b.mkv", :missing)

    # b's library path is taken, so its restore returns :trash_copy_retained
    # rather than a clean success. Both rows must still come back.
    File.write!(Path.join(ctx.root, "b.mkv"), "something else")

    assert :ok =
             perform_job(TrashAction, %{
               "action" => "restore",
               "selection" => %{"type" => "ids", "ids" => [a.id, b.id]}
             })

    assert is_nil(Repo.reload(a).trashed_at)
    assert is_nil(Repo.reload(b).trashed_at)
  end

  @tag :tmp_dir
  test "a restore failure does not stop the batch, and the failed row stays trashed", ctx do
    nested = Path.join(ctx.root, "nested")
    File.mkdir_p!(nested)

    a = trashed(ctx, "nested/a.mkv", :missing)
    b = trashed(ctx, "b.mkv", :missing)

    # a's directory emptied out when its file moved into the trash. Replacing
    # it with a plain file means restoring a means mkdir_p-ing over a file: a
    # structural failure that fails regardless of privilege, unlike a
    # permission bit, which a root-run test would sail straight through.
    File.rmdir!(nested)
    File.write!(nested, "not a directory anymore")

    assert :ok =
             perform_job(TrashAction, %{
               "action" => "restore",
               "selection" => %{"type" => "ids", "ids" => [a.id, b.id]}
             })

    refute is_nil(Repo.reload(a).trashed_at)
    assert is_nil(Repo.reload(b).trashed_at)
  end

  @tag :tmp_dir
  test "a purge failure does not stop the batch, and the failed row's row survives", ctx do
    a = trashed(ctx, "a.mkv", :pruned)
    b = trashed(ctx, "b.mkv", :pruned)

    # Swap a's trashed file for a directory of the same name. File.rm/1
    # refuses to unlink a directory, which fails structurally (unlike a
    # permission bit) so this is a real {:error, reason} out of
    # TrashStore.discard/2, not a contrived one.
    trash_path = a.metadata.extra["trashed_path"]
    File.rm!(trash_path)
    File.mkdir_p!(trash_path)

    assert :ok =
             perform_job(TrashAction, %{
               "action" => "purge",
               "selection" => %{"type" => "ids", "ids" => [a.id, b.id]}
             })

    refute is_nil(Repo.get(Mydia.Library.MediaFile, a.id))
    assert is_nil(Repo.get(Mydia.Library.MediaFile, b.id))
  end
end
