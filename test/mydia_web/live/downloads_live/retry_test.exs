defmodule MydiaWeb.DownloadsLive.RetryTest do
  use Mydia.DataCase, async: false

  import Mydia.DownloadsFixtures

  alias Mydia.Downloads
  alias MydiaWeb.DownloadsLive.Retry

  setup do
    # The app skips Oban in test, so start an isolated manual-mode instance.
    start_supervised!(
      {Oban, repo: Mydia.Repo, engine: Mydia.AdapterHelpers.oban_engine(), testing: :manual}
    )

    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  describe "regrab/1" do
    test "refuses an imported download and leaves the row alone" do
      imported =
        download_fixture(%{
          download_client: nil,
          download_client_id: nil,
          imported_at: now(),
          error_message: "stale failure"
        })

      assert {:error, :already_imported} = Retry.regrab(imported)
      assert Downloads.get_download(imported.id)
    end
  end

  describe "requeue_import/1" do
    test "clears the failure reason and reported path along with the error" do
      failed =
        download_fixture(%{
          download_client: nil,
          download_client_id: nil,
          import_failed_at: now(),
          import_last_error: "path mismatch",
          import_failure_reason: "path_mapping_mismatch",
          import_reported_path: "/remote/downloads/x",
          path_mapping_remote_prefix: "/downloads/complete",
          path_mapping_local_prefix: "/data/torrents/complete",
          path_mapping_searched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert {:ok, _job} = Retry.requeue_import(failed)

      reloaded = Downloads.get_download(failed.id)
      assert is_nil(reloaded.import_failure_reason)
      assert is_nil(reloaded.import_reported_path)
      assert is_nil(reloaded.import_last_error)
      assert reloaded.path_mapping_remote_prefix == nil
      assert reloaded.path_mapping_local_prefix == nil
      assert reloaded.path_mapping_searched_at == nil
    end
  end
end
