defmodule Mydia.Jobs.UpgradeCleanupTest do
  use Mydia.DataCase, async: true

  alias Mydia.Jobs.UpgradeCleanup
  alias Mydia.Library.MediaFile
  alias Mydia.Media.MediaItem
  alias Mydia.Settings.LibraryPath

  describe "perform/1" do
    setup do
      # Create a library path
      {:ok, library_path} =
        %LibraryPath{}
        |> Ecto.Changeset.change(%{
          path: "/media/movies",
          type: :movies,
          disabled: false
        })
        |> Repo.insert()

      # Create a media item
      {:ok, media_item} =
        %MediaItem{}
        |> Ecto.Changeset.change(%{
          title: "Test Movie",
          type: "movie",
          monitored: true
        })
        |> Repo.insert()

      # Create the "old" file (should be trashed on upgrade)
      {:ok, old_file} =
        %MediaFile{}
        |> Ecto.Changeset.change(%{
          media_item_id: media_item.id,
          library_path_id: library_path.id,
          path: "/media/movies/Test Movie/test.720p.mkv",
          relative_path: "Test Movie/test.720p.mkv",
          size: 2_000_000_000,
          resolution: "720p"
        })
        |> Repo.insert()

      # Create the "new" file (just imported from upgrade)
      {:ok, new_file} =
        %MediaFile{}
        |> Ecto.Changeset.change(%{
          media_item_id: media_item.id,
          library_path_id: library_path.id,
          path: "/media/movies/Test Movie/test.1080p.mkv",
          relative_path: "Test Movie/test.1080p.mkv",
          size: 4_000_000_000,
          resolution: "1080p"
        })
        |> Repo.insert()

      {:ok,
       media_item: media_item, old_file: old_file, new_file: new_file, library_path: library_path}
    end

    test "trashes old files and preserves new files", %{
      media_item: media_item,
      old_file: old_file,
      new_file: new_file
    } do
      # Default policy is "replace" — old files should be trashed
      job =
        UpgradeCleanup.new(%{
          "media_item_id" => media_item.id,
          "new_media_file_ids" => [new_file.id]
        })

      assert :ok = UpgradeCleanup.perform(%Oban.Job{args: job.changes.args})

      # Old file should be trashed
      old_file_reloaded = Repo.get!(MediaFile, old_file.id)
      assert old_file_reloaded.trashed_at != nil

      # New file should NOT be trashed
      new_file_reloaded = Repo.get!(MediaFile, new_file.id)
      assert new_file_reloaded.trashed_at == nil
    end

    test "does not trash already-trashed files", %{
      media_item: media_item,
      old_file: old_file,
      new_file: new_file
    } do
      # Pre-trash the old file
      old_file
      |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      job =
        UpgradeCleanup.new(%{
          "media_item_id" => media_item.id,
          "new_media_file_ids" => [new_file.id]
        })

      # Should succeed — no un-trashed old files to process
      assert :ok = UpgradeCleanup.perform(%Oban.Job{args: job.changes.args})
    end

    test "handles case when no old files exist", %{
      media_item: media_item,
      new_file: new_file,
      old_file: old_file
    } do
      # Delete the old file entirely
      Repo.delete!(old_file)

      job =
        UpgradeCleanup.new(%{
          "media_item_id" => media_item.id,
          "new_media_file_ids" => [new_file.id]
        })

      assert :ok = UpgradeCleanup.perform(%Oban.Job{args: job.changes.args})
    end

    test "does not trash files from other media items", %{
      media_item: media_item,
      new_file: new_file,
      library_path: library_path
    } do
      # Create another media item with a file
      {:ok, other_item} =
        %MediaItem{}
        |> Ecto.Changeset.change(%{
          title: "Other Movie",
          type: "movie",
          monitored: true
        })
        |> Repo.insert()

      {:ok, other_file} =
        %MediaFile{}
        |> Ecto.Changeset.change(%{
          media_item_id: other_item.id,
          library_path_id: library_path.id,
          path: "/media/movies/Other Movie/other.720p.mkv",
          relative_path: "Other Movie/other.720p.mkv",
          size: 2_000_000_000,
          resolution: "720p"
        })
        |> Repo.insert()

      job =
        UpgradeCleanup.new(%{
          "media_item_id" => media_item.id,
          "new_media_file_ids" => [new_file.id]
        })

      assert :ok = UpgradeCleanup.perform(%Oban.Job{args: job.changes.args})

      # Other movie's file should NOT be trashed
      other_file_reloaded = Repo.get!(MediaFile, other_file.id)
      assert other_file_reloaded.trashed_at == nil
    end
  end
end
