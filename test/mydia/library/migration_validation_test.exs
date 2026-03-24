defmodule Mydia.Library.MigrationValidationTest do
  @moduledoc """
  Tests for validating the relative path data migration.

  These tests verify that the migration correctly:
  1. Syncs runtime library paths to database
  2. Populates relative_path and library_path_id for all files
  3. Handles orphaned files gracefully
  4. Supports rollback safely
  """

  use Mydia.DataCase, async: true

  alias Mydia.Library.LibraryPathSync
  alias Mydia.Library.MediaFile
  alias Mydia.Settings
  alias Mydia.Settings.LibraryPath
  alias Mydia.Repo

  @moduletag :tmp_dir

  describe "library path sync from runtime config" do
    test "sync is idempotent - running multiple times is safe" do
      # First sync
      {:ok, %{synced: synced_count_1}} = LibraryPathSync.sync_from_runtime_config()
      assert synced_count_1 >= 0

      count_after_first = Repo.aggregate(LibraryPath, :count)

      # Second sync - should be idempotent
      {:ok, %{synced: synced_count_2}} = LibraryPathSync.sync_from_runtime_config()
      assert synced_count_2 >= 0

      count_after_second = Repo.aggregate(LibraryPath, :count)

      # Count should not increase on second sync (idempotent)
      assert count_after_second == count_after_first
    end
  end

  describe "media file relative path population" do
    test "populates relative_path and library_path_id for files within library", %{
      tmp_dir: tmp_dir
    } do
      lib_path = Path.join(tmp_dir, "movies")
      File.mkdir_p!(lib_path)

      {:ok, library_path} =
        Settings.create_library_path(%{
          path: lib_path,
          type: :movies,
          monitored: true
        })

      movie = insert(:media_item, type: "movie")

      # Create media file with absolute path (legacy format)
      absolute_path = Path.join(lib_path, "The Matrix (1999)/movie.mkv")

      changeset =
        %MediaFile{}
        |> Ecto.Changeset.change(%{
          path: absolute_path,
          media_item_id: movie.id,
          size: 1_000_000
        })
        # Skip normal validations since we're testing migration scenario
        |> Map.put(:valid?, true)

      {:ok, media_file} = Repo.insert(changeset)

      # Verify initial state: no relative_path or library_path_id
      assert media_file.relative_path == nil
      assert media_file.library_path_id == nil

      # Populate relative paths
      {:ok, _stats} = LibraryPathSync.populate_all_media_files()

      # Reload media file
      media_file = Repo.get!(MediaFile, media_file.id)

      # Verify relative_path and library_path_id were populated
      assert media_file.relative_path == "The Matrix (1999)/movie.mkv"
      assert media_file.library_path_id == library_path.id
    end

    test "handles orphaned files (outside configured library paths)", %{tmp_dir: tmp_dir} do
      lib_path = Path.join(tmp_dir, "movies")
      File.mkdir_p!(lib_path)

      {:ok, _library_path} =
        Settings.create_library_path(%{
          path: lib_path,
          type: :movies,
          monitored: true
        })

      movie = insert(:media_item, type: "movie")

      # Create file OUTSIDE library path
      orphaned_path = "/some/other/location/movie.mkv"

      changeset =
        %MediaFile{}
        |> Ecto.Changeset.change(%{
          path: orphaned_path,
          media_item_id: movie.id,
          size: 1_000_000
        })
        |> Map.put(:valid?, true)

      {:ok, media_file} = Repo.insert(changeset)

      # Populate relative paths
      {:ok, stats} = LibraryPathSync.populate_all_media_files()

      # Verify orphaned file was tracked
      assert stats.orphaned >= 1

      # Reload media file
      media_file = Repo.get!(MediaFile, media_file.id)

      # Orphaned file should NOT have relative_path or library_path_id
      assert media_file.relative_path == nil
      assert media_file.library_path_id == nil
    end

    test "uses longest prefix matching for nested library paths", %{tmp_dir: tmp_dir} do
      # Create nested library paths
      base_path = Path.join(tmp_dir, "media")
      movies_path = Path.join(base_path, "movies")
      File.mkdir_p!(movies_path)

      {:ok, _base_library} =
        Settings.create_library_path(%{
          path: base_path,
          type: :mixed,
          monitored: true
        })

      {:ok, movies_library} =
        Settings.create_library_path(%{
          path: movies_path,
          type: :movies,
          monitored: true
        })

      movie = insert(:media_item, type: "movie")

      # Create file in nested path
      absolute_path = Path.join(movies_path, "Inception (2010)/movie.mkv")

      changeset =
        %MediaFile{}
        |> Ecto.Changeset.change(%{
          path: absolute_path,
          media_item_id: movie.id,
          size: 1_000_000
        })
        |> Map.put(:valid?, true)

      {:ok, media_file} = Repo.insert(changeset)

      # Populate
      {:ok, _stats} = LibraryPathSync.populate_all_media_files()

      # Reload
      media_file = Repo.get!(MediaFile, media_file.id)

      # Should match the more specific (longer) path
      assert media_file.library_path_id == movies_library.id
      assert media_file.relative_path == "Inception (2010)/movie.mkv"
    end

    test "handles files with special characters in path", %{tmp_dir: tmp_dir} do
      lib_path = Path.join(tmp_dir, "series")
      File.mkdir_p!(lib_path)

      {:ok, library_path} =
        Settings.create_library_path(%{
          path: lib_path,
          type: :series,
          monitored: true
        })

      tv_show = insert(:tv_show)
      episode = insert(:episode, media_item: tv_show)

      # File with special characters
      absolute_path = Path.join(lib_path, "It's Always Sunny/S01E01 - Charlie's Mom.mkv")

      changeset =
        %MediaFile{}
        |> Ecto.Changeset.change(%{
          path: absolute_path,
          media_item_id: tv_show.id,
          episode_id: episode.id,
          size: 500_000
        })
        |> Map.put(:valid?, true)

      {:ok, media_file} = Repo.insert(changeset)

      # Populate
      {:ok, _stats} = LibraryPathSync.populate_all_media_files()

      # Reload
      media_file = Repo.get!(MediaFile, media_file.id)

      assert media_file.relative_path == "It's Always Sunny/S01E01 - Charlie's Mom.mkv"
      assert media_file.library_path_id == library_path.id
    end
  end

  describe "migration statistics" do
    test "returns accurate statistics", %{tmp_dir: tmp_dir} do
      lib_path = Path.join(tmp_dir, "movies")
      File.mkdir_p!(lib_path)

      {:ok, _library_path} =
        Settings.create_library_path(%{
          path: lib_path,
          type: :movies,
          monitored: true
        })

      # Create 3 files: 2 in library, 1 orphaned
      movie1 = insert(:media_item, type: "movie")
      movie2 = insert(:media_item, type: "movie")
      movie3 = insert(:media_item, type: "movie")

      # File 1: Inside library
      file1_path = Path.join(lib_path, "movie1.mkv")

      changeset1 =
        %MediaFile{}
        |> Ecto.Changeset.change(%{
          path: file1_path,
          media_item_id: movie1.id,
          size: 1_000_000
        })
        |> Map.put(:valid?, true)

      {:ok, _} = Repo.insert(changeset1)

      # File 2: Inside library
      file2_path = Path.join(lib_path, "movie2.mkv")

      changeset2 =
        %MediaFile{}
        |> Ecto.Changeset.change(%{
          path: file2_path,
          media_item_id: movie2.id,
          size: 1_000_000
        })
        |> Map.put(:valid?, true)

      {:ok, _} = Repo.insert(changeset2)

      # File 3: Orphaned (outside library)
      file3_path = "/external/movie3.mkv"

      changeset3 =
        %MediaFile{}
        |> Ecto.Changeset.change(%{
          path: file3_path,
          media_item_id: movie3.id,
          size: 1_000_000
        })
        |> Map.put(:valid?, true)

      {:ok, _} = Repo.insert(changeset3)

      # Populate
      {:ok, stats} = LibraryPathSync.populate_all_media_files()

      # Verify statistics
      assert stats.updated >= 2
      assert stats.orphaned >= 1
      assert stats.failed == 0
    end
  end

  describe "rollback safety" do
    test "can rollback by clearing relative_path and library_path_id", %{tmp_dir: tmp_dir} do
      lib_path = Path.join(tmp_dir, "movies")
      File.mkdir_p!(lib_path)

      {:ok, _library_path} =
        Settings.create_library_path(%{
          path: lib_path,
          type: :movies,
          monitored: true
        })

      movie = insert(:media_item, type: "movie")

      # Create and populate media file
      absolute_path = Path.join(lib_path, "movie.mkv")

      changeset =
        %MediaFile{}
        |> Ecto.Changeset.change(%{
          path: absolute_path,
          media_item_id: movie.id,
          size: 1_000_000
        })
        |> Map.put(:valid?, true)

      {:ok, media_file} = Repo.insert(changeset)

      # Populate (simulate migration up)
      {:ok, _stats} = LibraryPathSync.populate_all_media_files()

      media_file = Repo.get!(MediaFile, media_file.id)
      assert media_file.relative_path != nil
      assert media_file.library_path_id != nil

      # Rollback (simulate migration down)
      Repo.update_all(MediaFile, set: [relative_path: nil, library_path_id: nil])

      # Verify rollback
      media_file = Repo.get!(MediaFile, media_file.id)
      assert media_file.relative_path == nil
      assert media_file.library_path_id == nil
      # Original path field should still exist
      assert media_file.path == absolute_path
    end

    test "rollback preserves original path field", %{tmp_dir: tmp_dir} do
      lib_path = Path.join(tmp_dir, "movies")
      File.mkdir_p!(lib_path)

      {:ok, _library_path} =
        Settings.create_library_path(%{
          path: lib_path,
          type: :movies,
          monitored: true
        })

      movie = insert(:media_item, type: "movie")
      original_path = Path.join(lib_path, "original/path/to/movie.mkv")

      changeset =
        %MediaFile{}
        |> Ecto.Changeset.change(%{
          path: original_path,
          media_item_id: movie.id,
          size: 1_000_000
        })
        |> Map.put(:valid?, true)

      {:ok, media_file} = Repo.insert(changeset)

      # Populate
      {:ok, _stats} = LibraryPathSync.populate_all_media_files()

      # Rollback
      Repo.update_all(MediaFile, set: [relative_path: nil, library_path_id: nil])

      # Verify original path is intact
      media_file = Repo.get!(MediaFile, media_file.id)
      assert media_file.path == original_path
    end
  end
end
