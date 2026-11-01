defmodule Mydia.Jobs.MediaImport.FailurePathMappingTest do
  use Mydia.DataCase, async: true

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads
  alias Mydia.Jobs.MediaImport.Failure

  defp download(attrs \\ %{}) do
    media_item = media_item_fixture()
    download_fixture(Map.merge(%{media_item_id: media_item.id, status: "completed"}, attrs))
  end

  test "a mismatch failure stamps the search with the failure" do
    d = download()

    :ok =
      Failure.handle_import_failure(
        d,
        {:path_mapping_mismatch, "/downloads/complete/Fictional.Salt.Meridian.S01E01"},
        1,
        terminal?: true
      )

    updated = Downloads.get_download!(d.id)
    assert updated.import_failure_reason == "path_mapping_mismatch"
    # The test config searches no roots, so nothing matches, but the search ran.
    assert %DateTime{} = updated.path_mapping_searched_at
    assert updated.path_mapping_remote_prefix == nil
    assert updated.path_mapping_local_prefix == nil
  end

  test "any other failure clears a suggestion left over from an earlier one" do
    d =
      download(%{
        path_mapping_remote_prefix: "/downloads/complete",
        path_mapping_local_prefix: "/data/torrents/complete",
        path_mapping_searched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    :ok = Failure.handle_import_failure(d, :no_files, 1)

    updated = Downloads.get_download!(d.id)
    assert updated.import_failure_reason == "no_files"
    assert updated.path_mapping_remote_prefix == nil
    assert updated.path_mapping_local_prefix == nil
    assert updated.path_mapping_searched_at == nil
  end
end
