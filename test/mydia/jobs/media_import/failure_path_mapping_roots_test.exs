defmodule Mydia.Jobs.MediaImport.FailurePathMappingRootsTest do
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads
  alias Mydia.Jobs.MediaImport.Failure

  @reported "/downloads/complete/Fictional.Salt.Meridian.S01E01"

  setup do
    previous = Application.get_env(:mydia, :path_mapping_roots)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:mydia, :path_mapping_roots),
        else: Application.put_env(:mydia, :path_mapping_roots, previous)
    end)

    media_item = media_item_fixture()
    %{download: download_fixture(%{media_item_id: media_item.id, status: "completed"})}
  end

  test "a found directory is stored as the suggestion", %{download: d} do
    root = Path.join(System.tmp_dir!(), "pm_roots_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "complete/Fictional.Salt.Meridian.S01E01"))
    on_exit(fn -> File.rm_rf!(root) end)
    Application.put_env(:mydia, :path_mapping_roots, [root])

    :ok =
      Failure.handle_import_failure(d, {:path_mapping_mismatch, @reported}, 1, terminal?: true)

    updated = Downloads.get_download!(d.id)
    assert updated.path_mapping_remote_prefix == "/downloads/complete"
    assert updated.path_mapping_local_prefix == Path.join(root, "complete")
  end

  test "a crashing search still records the failure", %{download: d} do
    Application.put_env(:mydia, :path_mapping_roots, [123])

    log =
      capture_log(fn ->
        :ok =
          Failure.handle_import_failure(d, {:path_mapping_mismatch, @reported}, 1,
            terminal?: true
          )
      end)

    updated = Downloads.get_download!(d.id)
    assert updated.import_failure_reason == "path_mapping_mismatch"
    assert %DateTime{} = updated.path_mapping_searched_at
    assert updated.path_mapping_remote_prefix == nil
    assert updated.path_mapping_local_prefix == nil
    assert log =~ @reported
  end
end
