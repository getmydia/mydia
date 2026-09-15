defmodule Mydia.Downloads.DownloadRemovalStateTest do
  use Mydia.DataCase, async: true

  import Mydia.DownloadsFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.Download

  describe "Download.changeset/2 removal fields" do
    test "accepts each removal kind" do
      for kind <- ~w(cancel clear reject) do
        changeset =
          Download.changeset(%Download{}, %{title: "Fictional Release", removal_kind: kind})

        assert changeset.valid?, "expected #{kind} to be accepted"
      end
    end

    test "rejects an unknown removal kind" do
      changeset =
        Download.changeset(%Download{}, %{title: "Fictional Release", removal_kind: "purge"})

      refute changeset.valid?
      assert %{removal_kind: _} = errors_on(changeset)
    end
  end

  describe "list_downloads_with_status/1" do
    test "carries the removal columns onto the enriched row" do
      requested_at = DateTime.utc_now() |> DateTime.truncate(:second)

      download =
        download_fixture(%{
          removal_requested_at: requested_at,
          removal_kind: "clear",
          removal_delete_files: true,
          removal_error: "Failed to remove torrent"
        })

      enriched =
        Downloads.list_downloads_with_status(filter: :all)
        |> Enum.find(&(&1.id == download.id))

      assert enriched.removal_requested_at == requested_at
      assert enriched.removal_kind == "clear"
      assert enriched.removal_delete_files == true
      assert enriched.removal_error == "Failed to remove torrent"
    end
  end
end
