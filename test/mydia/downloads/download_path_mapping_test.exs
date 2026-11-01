defmodule Mydia.Downloads.DownloadPathMappingTest do
  use Mydia.DataCase, async: true

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.Download

  defp mismatch(attrs) do
    media_item = media_item_fixture()

    download_fixture(
      Map.merge(
        %{
          media_item_id: media_item.id,
          status: "completed",
          import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          import_failure_reason: "path_mapping_mismatch",
          import_reported_path: "/downloads/complete/Fictional.Salt.Meridian.S01E01"
        },
        attrs
      )
    )
  end

  test "casts and persists the stored suggestion" do
    searched_at = DateTime.utc_now() |> DateTime.truncate(:second)

    download =
      mismatch(%{
        path_mapping_remote_prefix: "/downloads/complete",
        path_mapping_local_prefix: "/data/torrents/complete",
        path_mapping_searched_at: searched_at
      })

    reloaded = Downloads.get_download!(download.id)
    assert reloaded.path_mapping_remote_prefix == "/downloads/complete"
    assert reloaded.path_mapping_local_prefix == "/data/torrents/complete"
    assert reloaded.path_mapping_searched_at == searched_at
  end

  describe "path_mapping_suggestion/1" do
    test "builds the map when both prefixes are stored" do
      assert Download.path_mapping_suggestion(%Download{
               path_mapping_remote_prefix: "/r",
               path_mapping_local_prefix: "/l"
             }) == %{remote_prefix: "/r", local_prefix: "/l"}
    end

    test "is nil when either prefix is missing" do
      assert Download.path_mapping_suggestion(%Download{}) == nil

      assert Download.path_mapping_suggestion(%Download{path_mapping_remote_prefix: "/r"}) ==
               nil
    end
  end

  test "cleared_import_failure_attrs/0 also clears the stored suggestion" do
    attrs = Download.cleared_import_failure_attrs()

    assert attrs.import_failure_reason == nil
    assert attrs.import_reported_path == nil
    assert attrs.import_retry_count == 0
    assert attrs.path_mapping_remote_prefix == nil
    assert attrs.path_mapping_local_prefix == nil
    assert attrs.path_mapping_searched_at == nil
  end

  test "list_downloads_with_status carries the stored suggestion onto the row" do
    download =
      mismatch(%{
        path_mapping_remote_prefix: "/downloads/complete",
        path_mapping_local_prefix: "/data/torrents/complete"
      })

    row =
      Downloads.list_downloads_with_status(bounded: true)
      |> Enum.find(&(&1.id == download.id))

    assert row.path_mapping_suggestion == %{
             remote_prefix: "/downloads/complete",
             local_prefix: "/data/torrents/complete"
           }
  end
end
