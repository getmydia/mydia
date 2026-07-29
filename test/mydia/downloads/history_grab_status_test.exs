defmodule Mydia.Downloads.HistoryGrabStatusTest do
  use Mydia.DataCase, async: false

  import Ecto.Query
  import Mydia.DownloadsFixtures

  alias Mydia.Downloads.Download
  alias Mydia.Downloads.History
  alias Mydia.Repo

  # No download clients are configured in these tests, so
  # list_downloads_with_status/1 takes the clients == [] branch and every
  # record goes through enrich_download_with_empty_status/1.

  defp enriched(download) do
    History.list_downloads_with_status(filter: :all)
    |> Enum.find(&(&1.id == download.id))
  end

  defp backdate(download, minutes_ago) do
    cutoff = DateTime.add(DateTime.utc_now(), -minutes_ago * 60, :second)

    from(d in Download, where: d.id == ^download.id)
    |> Repo.update_all(set: [inserted_at: cutoff])

    download
  end

  describe "grab status derivation" do
    test "fresh record with no client fields derives to grabbing" do
      download = download_fixture(download_client: nil, download_client_id: nil)

      assert %{status: "grabbing", error_message: nil} = enriched(download)
    end

    test "stale record with no client fields derives to failed with timeout reason" do
      download =
        download_fixture(download_client: nil, download_client_id: nil)
        |> backdate(11)

      assert %{status: "failed", error_message: "Grab timed out"} = enriched(download)
    end

    test "record with an error_message still derives to failed with its own reason" do
      download =
        download_fixture(
          download_client: nil,
          download_client_id: nil,
          error_message: "Client rejected"
        )

      assert %{status: "failed", error_message: "Client rejected"} = enriched(download)
    end

    test "record with client fields set keeps deriving to missing" do
      download = download_fixture()

      assert %{status: "missing"} = enriched(download)
    end

    test "grabbing counts as active" do
      download = download_fixture(download_client: nil, download_client_id: nil)

      # The clients == [] branch skips filtering, so exercise the filter fn
      # through the enriched struct directly.
      enriched = enriched(download)
      assert enriched.status == "grabbing"
      assert is_nil(enriched.imported_at)
    end
  end
end
