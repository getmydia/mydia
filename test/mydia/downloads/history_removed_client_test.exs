defmodule Mydia.Downloads.HistoryRemovedClientTest do
  @moduledoc """
  The Issues-tab bulk clear must be scoped. `dismiss_all_cancelled/0` already
  exists and deletes every errored row in the tab; these functions delete only
  one removed client's orphans, leaving other clients and other failure
  reasons alone.
  """
  use Mydia.DataCase, async: true

  alias Mydia.Downloads

  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures

  describe "count_downloads_for_client/1" do
    test "counts every unimported row for that client, not only orphaned ones" do
      media_item = media_item_fixture()

      download_fixture(%{media_item_id: media_item.id, download_client: "qbit"})
      download_fixture(%{media_item_id: media_item.id, download_client: "qbit"})
      download_fixture(%{media_item_id: media_item.id, download_client: "other"})

      # This runs before deletion, while the client still exists, so a healthy
      # in-flight download counts toward the warning's blast radius.
      assert Downloads.count_downloads_for_client("qbit") == 2
      assert Downloads.count_downloads_for_client("other") == 1
      assert Downloads.count_downloads_for_client("absent") == 0
    end

    test "excludes imported downloads" do
      # Import does not delete the row: `MediaImport` stamps `imported_at` and
      # leaves it as history, which is why `count_completed/0` exists. On a
      # mature instance that history dwarfs the in-flight downloads, and
      # deleting the client does nothing at all to it, so counting it would
      # make the warning report a blast radius that is mostly fiction.
      media_item = media_item_fixture()

      download_fixture(%{media_item_id: media_item.id, download_client: "qbit"})

      for _ <- 1..3 do
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "qbit",
          imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
      end

      assert Downloads.count_downloads_for_client("qbit") == 1
    end
  end

  describe "removed_client_groups/0" do
    test "groups orphans by client name with counts" do
      media_item = media_item_fixture()

      for _ <- 1..3 do
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "qbit-old",
          error_message: "gone",
          import_failure_reason: "no_client"
        })
      end

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "sab-old",
        error_message: "gone",
        import_failure_reason: "no_client"
      })

      # Not an orphan: different failure reason.
      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "qbit-old",
        error_message: "something else",
        import_failure_reason: "path_mapping_mismatch"
      })

      groups = Enum.sort_by(Downloads.removed_client_groups(), & &1.download_client)

      assert groups == [
               %{download_client: "qbit-old", count: 3},
               %{download_client: "sab-old", count: 1}
             ]
    end

    test "returns an empty list when there are no orphans" do
      media_item = media_item_fixture()
      download_fixture(%{media_item_id: media_item.id, download_client: "qbit"})

      assert Downloads.removed_client_groups() == []
    end
  end

  describe "clear_downloads_for_removed_client/1" do
    test "deletes only that client's orphans" do
      media_item = media_item_fixture()

      target =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "qbit-old",
          error_message: "gone",
          import_failure_reason: "no_client"
        })

      other_client =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "sab-old",
          error_message: "gone",
          import_failure_reason: "no_client"
        })

      other_reason =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "qbit-old",
          error_message: "something else",
          import_failure_reason: "path_mapping_mismatch"
        })

      healthy =
        download_fixture(%{media_item_id: media_item.id, download_client: "qbit-old"})

      assert {1, _} = Downloads.clear_downloads_for_removed_client("qbit-old")

      assert_raise Ecto.NoResultsError, fn -> Downloads.get_download!(target.id) end

      assert Downloads.get_download!(other_client.id)
      assert Downloads.get_download!(other_reason.id)
      assert Downloads.get_download!(healthy.id)
    end
  end
end
