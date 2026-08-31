defmodule Mydia.Repo.Migrations.MarkExistingTrashedFilesAsMissingTest do
  @moduledoc """
  Merge-gate backfill: the trash system has been soft-trashing missing files
  since v0.10.0 while the purge deleted no bytes at all, so this branch turns
  byte deletion on for five months of accumulated rows that are predominantly
  unmount-shaped rather than deliberate deletes. Every one of them has to reach
  the new code already marked as trashed-while-missing.
  """
  use Mydia.DataCase, async: false

  import Mydia.SettingsFixtures

  # Migration modules are not compiled into the app, so load the file explicitly.
  Code.require_file(
    "priv/repo/migrations/20260731120000_mark_existing_trashed_files_as_missing.exs"
  )

  alias Mydia.Library
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Repo
  alias Mydia.Repo.Migrations.MarkExistingTrashedFilesAsMissing, as: Migration

  describe "mark/1" do
    test "adds the marker at the top level, where FileMetadata stores extra keys" do
      assert Migration.mark(%{}) == %{"trashed_missing" => true}
    end

    test "preserves everything already in the metadata map" do
      metadata = %{"container" => "mkv", "duration" => 5400.5, "custom" => %{"a" => 1}}

      assert Migration.mark(metadata) == Map.put(metadata, "trashed_missing", true)
    end

    test "leaves a row that already records where its bytes went alone" do
      metadata = %{"trashed_path" => "/media/.mydia-trash/abc/movie.mkv"}

      assert Migration.mark(metadata) == metadata
    end
  end

  describe "unmark/1" do
    test "removes only the marker" do
      assert Migration.unmark(%{"container" => "mkv", "trashed_missing" => true}) ==
               %{"container" => "mkv"}
    end
  end

  describe "backfill/2 against the database" do
    @tag :tmp_dir
    test "a pre-existing trashed row survives a purge with its file intact", %{tmp_dir: tmp_dir} do
      # A row exactly as v0.10.0 through v0.12.0 left it: trashed_at set, no
      # trashed_path, no marker - and a file present at the library path,
      # because the unmounted share came back.
      {media_file, path} = legacy_trashed_row(tmp_dir, "kept.mkv")

      assert :ok = Migration.backfill(Repo, :mark)

      assert {:ok, 1} = Library.purge_old_trashed_media_files(30)

      assert File.read!(path) == "video bytes"
      assert is_nil(Library.get_media_file(media_file.id))
    end

    @tag :tmp_dir
    test "preserves the rest of the metadata it rewrites", %{tmp_dir: tmp_dir} do
      {media_file, _path} =
        legacy_trashed_row(tmp_dir, "meta.mkv", %FileMetadata{container: "mkv", duration: 42.0})

      assert :ok = Migration.backfill(Repo, :mark)

      reloaded = Repo.reload!(media_file)
      assert reloaded.metadata.container == "mkv"
      assert reloaded.metadata.duration == 42.0
      assert reloaded.metadata.extra["trashed_missing"] == true
    end

    @tag :tmp_dir
    test "leaves untrashed rows untouched", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "lib")
      File.mkdir_p!(root)
      library_path = library_path_fixture(%{path: root, type: "movies"})

      {:ok, active} =
        Library.create_scanned_media_file(%{
          relative_path: "active.mkv",
          library_path_id: library_path.id,
          media_item_id: insert(:media_item, type: "movie").id,
          size: 11,
          metadata: %FileMetadata{container: "mkv"}
        })

      assert :ok = Migration.backfill(Repo, :mark)

      reloaded = Repo.reload!(active)
      assert reloaded.metadata.container == "mkv"
      assert reloaded.metadata.extra["trashed_missing"] == nil
    end

    # The realistic shape for a scanned file that was never analyzed: the
    # metadata column is NULL, so the migration has nothing to decode.
    @tag :tmp_dir
    test "marks a trashed row whose metadata column is null", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "lib")
      File.mkdir_p!(root)
      path = Path.join(root, "null_meta.mkv")
      File.write!(path, "video bytes")
      library_path = library_path_fixture(%{path: root, type: "movies"})

      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "null_meta.mkv",
          library_path_id: library_path.id,
          media_item_id: insert(:media_item, type: "movie").id,
          size: 11
        })

      trashed_at = DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.truncate(:second)

      media_file =
        media_file |> Ecto.Changeset.change(trashed_at: trashed_at) |> Repo.update!()

      assert :ok = Migration.backfill(Repo, :mark)

      assert Repo.reload!(media_file).metadata.extra["trashed_missing"] == true

      assert {:ok, 1} = Library.purge_old_trashed_media_files(30)
      assert File.exists?(path)
    end

    @tag :tmp_dir
    test "the unmark direction removes the marker again", %{tmp_dir: tmp_dir} do
      {media_file, _path} = legacy_trashed_row(tmp_dir, "unmark.mkv")

      assert :ok = Migration.backfill(Repo, :mark)
      assert Repo.reload!(media_file).metadata.extra["trashed_missing"] == true

      assert :ok = Migration.backfill(Repo, :unmark)
      assert Repo.reload!(media_file).metadata.extra["trashed_missing"] == nil
    end
  end

  describe "down/0" do
    # mix ecto.rollback does not imply rolling the code back. If down/0 stripped
    # the marker while a deployment was still running this branch, every trashed
    # row would become :legacy again and the next daily TrashCleanup would delete
    # it at the library path - the exact loss this migration prevents, triggered
    # by a routine command. Leaving the key is inert to every pre-branch version.
    @tag :tmp_dir
    test "does not strip the marker it added", %{tmp_dir: tmp_dir} do
      {media_file, path} = legacy_trashed_row(tmp_dir, "rollback.mkv")

      assert :ok = Migration.backfill(Repo, :mark)
      assert :ok = Migration.down()

      assert Repo.reload!(media_file).metadata.extra["trashed_missing"] == true

      # And the protection still holds afterwards.
      assert {:ok, 1} = Library.purge_old_trashed_media_files(30)
      assert File.read!(path) == "video bytes"
    end
  end

  # A trashed row in the pre-TrashStore shape, with its file present on disk.
  # Built by writing trashed_at directly rather than through
  # Library.trash_media_file/1, which is exactly the point: the released code
  # only ever stamped the timestamp.
  defp legacy_trashed_row(tmp_dir, name, metadata \\ %FileMetadata{}) do
    root = Path.join(tmp_dir, "lib")
    File.mkdir_p!(root)
    path = Path.join(root, name)
    File.write!(path, "video bytes")

    library_path = library_path_fixture(%{path: root, type: "movies"})

    {:ok, media_file} =
      Library.create_scanned_media_file(%{
        relative_path: name,
        library_path_id: library_path.id,
        media_item_id: insert(:media_item, type: "movie").id,
        size: byte_size("video bytes")
      })

    trashed_at = DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.truncate(:second)

    media_file =
      media_file
      |> Ecto.Changeset.change(trashed_at: trashed_at, metadata: metadata)
      |> Repo.update!()

    {media_file, path}
  end
end
