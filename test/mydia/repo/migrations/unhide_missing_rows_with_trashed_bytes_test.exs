defmodule Mydia.Repo.Migrations.UnhideMissingRowsWithTrashedBytesTest do
  @moduledoc """
  A scan could move a file that reappeared mid-scan into the trash on a row
  stamped `:missing`. Those rows are hidden from the trash page, so the
  migration clears their reason to bring them back into view.
  """
  use Mydia.DataCase, async: false

  import Mydia.SettingsFixtures

  Code.require_file(
    "priv/repo/migrations/20261028014807_unhide_missing_rows_with_trashed_bytes.exs"
  )

  alias Mydia.Library
  alias Mydia.Repo
  alias Mydia.Repo.Migrations.UnhideMissingRowsWithTrashedBytes, as: Migration

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    trash_root = Path.join(tmp_dir, "trash")
    File.mkdir_p!(trash_root)
    Application.put_env(:mydia, :trash_dir, trash_root)
    on_exit(fn -> Application.delete_env(:mydia, :trash_dir) end)

    root = Path.join(tmp_dir, "lib")
    File.mkdir_p!(root)
    %{root: root, library_path: library_path_fixture(%{path: root, type: "movies"})}
  end

  defp trashed(ctx, name, reason, opts) do
    if Keyword.get(opts, :on_disk, true), do: File.write!(Path.join(ctx.root, name), "x")

    {:ok, media_file} =
      Library.create_scanned_media_file(%{
        relative_path: name,
        library_path_id: ctx.library_path.id,
        media_item_id: insert(:media_item, type: "movie").id,
        size: 1
      })

    {:ok, t} = Library.trash_media_file(Repo.preload(media_file, :library_path), reason: reason)
    t
  end

  defp visible?(row), do: Enum.any?(Library.list_trashed_media_files(), &(&1.id == row.id))

  test "a :missing row whose bytes were moved becomes visible as unknown", ctx do
    row = trashed(ctx, "moved.mkv", :missing, on_disk: true)
    assert is_binary(row.metadata.extra["trashed_path"])
    refute visible?(row)

    assert :ok = Migration.unhide(Repo)

    reloaded = Repo.reload!(row)
    assert is_nil(reloaded.trashed_reason)
    assert %DateTime{} = reloaded.trashed_at
    assert reloaded.metadata.extra["trashed_path"] == row.metadata.extra["trashed_path"]
    assert visible?(reloaded)
  end

  test "a :missing row with nothing in the trash stays hidden", ctx do
    row = trashed(ctx, "gone.mkv", :missing, on_disk: false)
    assert row.metadata.extra["trashed_missing"] == true

    assert :ok = Migration.unhide(Repo)

    assert %{trashed_reason: :missing} = Repo.reload!(row)
    refute visible?(row)
  end

  test "other reasons are left alone even with bytes in the trash", ctx do
    row = trashed(ctx, "pruned.mkv", :pruned, on_disk: true)

    assert :ok = Migration.unhide(Repo)

    assert %{trashed_reason: :pruned} = Repo.reload!(row)
  end

  describe "holds_trash_copy?/1" do
    test "needs a non-empty trashed_path" do
      assert Migration.holds_trash_copy?(%{"trashed_path" => "/t/1/a.mkv"})
      refute Migration.holds_trash_copy?(%{"trashed_path" => ""})
      refute Migration.holds_trash_copy?(%{"trashed_missing" => true})
      refute Migration.holds_trash_copy?(%{})
    end
  end
end
