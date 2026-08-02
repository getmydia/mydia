defmodule Mydia.Repo.Migrations.DropUnmatchedDownloadRowsTest do
  use Mydia.DataCase, async: false

  alias Mydia.Downloads.Download
  alias Mydia.Repo

  import Ecto.Query
  import Mydia.DownloadsFixtures

  # The exact statement the migration runs. It has no parameters, so it is
  # adapter-agnostic and needs no placeholder translation.
  @sql "DELETE FROM downloads WHERE match_status = 'unmatched'"

  # The schema no longer accepts "unmatched", so the fixture is written with
  # update_all, which bypasses changeset validation.
  defp with_match_status(download, status) do
    {1, _} =
      from(d in Download, where: d.id == ^download.id)
      |> Repo.update_all(set: [match_status: status])

    download
  end

  test "deletes unmatched rows and leaves the other match statuses alone" do
    unmatched = download_fixture() |> with_match_status("unmatched")
    unresolved = download_fixture() |> with_match_status("unresolved_files")

    Repo.query!(@sql)

    refute Repo.exists?(from d in Download, where: d.id == ^unmatched.id)
    assert Repo.exists?(from d in Download, where: d.id == ^unresolved.id)
  end
end
