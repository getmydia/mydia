defmodule Mydia.Jobs.MediaImportRemovalPendingTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.DownloadsFixtures

  alias Mydia.Downloads.Download
  alias Mydia.Jobs.MediaImport
  alias Mydia.Repo

  test "does not import a download the operator asked to remove" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    download =
      download_fixture(%{completed_at: now, removal_requested_at: now, removal_kind: "cancel"})

    assert :ok =
             perform_job(MediaImport, %{
               "download_id" => download.id,
               "save_path" => "/nonexistent/fictional-downloads"
             })

    row = Repo.get!(Download, download.id)
    assert is_nil(row.imported_at)
    assert is_nil(row.import_last_error)
    assert is_nil(row.import_failed_at)
  end
end
