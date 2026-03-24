defmodule Mydia.Jobs.TrashCleanupTest do
  use Mydia.DataCase

  alias Mydia.Jobs.TrashCleanup
  alias Mydia.Library

  import Mydia.SettingsFixtures

  describe "perform/1" do
    test "purges trashed files older than retention period" do
      library_path =
        library_path_fixture(%{
          path: "/cleanup_test_#{System.unique_integer([:positive])}",
          type: "movies"
        })

      {:ok, media_item} =
        Mydia.Media.create_media_item(%{type: "movie", title: "Cleanup Test", year: 2024})

      # Create and trash a file
      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "old_cleanup.mp4",
          library_path_id: library_path.id,
          media_item_id: media_item.id,
          size: 1_000_000
        })

      {:ok, _} = Library.trash_media_file(media_file)

      # Backdate trashed_at to 31 days ago
      old_trashed_at =
        DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.truncate(:second)

      media_file
      |> Ecto.Changeset.change(trashed_at: old_trashed_at)
      |> Mydia.Repo.update!()

      # Run the cleanup job
      assert :ok = TrashCleanup.perform(%Oban.Job{args: %{}})

      # File should be permanently deleted
      assert is_nil(Library.get_media_file(media_file.id))
    end

    test "does not purge recently trashed files" do
      library_path =
        library_path_fixture(%{
          path: "/cleanup_recent_#{System.unique_integer([:positive])}",
          type: "movies"
        })

      {:ok, media_item} =
        Mydia.Media.create_media_item(%{type: "movie", title: "Recent Cleanup", year: 2024})

      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "recent_cleanup.mp4",
          library_path_id: library_path.id,
          media_item_id: media_item.id,
          size: 1_000_000
        })

      {:ok, _} = Library.trash_media_file(media_file)

      # Run the cleanup job — file was just trashed, should survive
      assert :ok = TrashCleanup.perform(%Oban.Job{args: %{}})

      # File should still exist (trashed but not yet purged)
      assert not is_nil(Library.get_media_file(media_file.id))
    end
  end
end
