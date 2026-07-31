defmodule Mydia.Downloads.ExternalTorrentsTest do
  use Mydia.DataCase, async: false

  alias Mydia.Downloads.ExternalTorrents
  alias Mydia.Downloads.Structs.{DownloadStatus, ExternalScan, ExternalTorrent}

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  defp status(name, id) do
    %DownloadStatus{
      id: id,
      name: name,
      state: :seeding,
      progress: 100.0,
      size: 1_000_000,
      save_path: "/downloads"
    }
  end

  describe "subtract_known/1" do
    test "keeps a torrent Mydia knows nothing about" do
      listings = [{"qbit", [status("ubuntu-24.04.iso", "hash-a")]}]

      assert [{"qbit", %DownloadStatus{id: "hash-a"}}] =
               ExternalTorrents.subtract_known(listings)
    end

    test "drops a torrent that is already a tracked download" do
      download_fixture(%{download_client: "qbit", download_client_id: "hash-a"})
      listings = [{"qbit", [status("Tracked.Release.2024", "hash-a")]}]

      assert ExternalTorrents.subtract_known(listings) == []
    end

    test "keeps a torrent tracked under a different client name" do
      download_fixture(%{download_client: "transmission", download_client_id: "hash-a"})
      listings = [{"qbit", [status("Release.2024", "hash-a")]}]

      assert [{"qbit", _}] = ExternalTorrents.subtract_known(listings)
    end

    test "the batched imported lookup agrees with the per-pair check" do
      # subtract_known/1 batches what torrent_already_imported?/2 answers one at
      # a time. The two must not disagree, or a foreign torrent either vanishes
      # or reappears after import.
      media_file_fixture(%{
        metadata: %{"download_client" => "qbit", "download_client_id" => "hash-in"}
      })

      pairs = [{"qbit", "hash-in"}, {"qbit", "hash-out"}, {"other", "hash-in"}]
      batched = Mydia.Library.imported_torrent_pairs(pairs)

      for {client, id} <- pairs do
        assert MapSet.member?(batched, {client, id}) ==
                 Mydia.Library.torrent_already_imported?(client, id),
               "batched and per-pair disagree on #{client}/#{id}"
      end

      assert MapSet.member?(batched, {"qbit", "hash-in"})
    end

    test "the batched imported lookup handles an empty candidate list" do
      assert Mydia.Library.imported_torrent_pairs([]) == MapSet.new()
    end

    test "drops a torrent whose files were imported after its download row was cleared" do
      # "Clear Completed" deletes the download row, but the imported files keep
      # the provenance pair, which is the only thing left to recognise it by.
      media_file_fixture(%{
        metadata: %{"download_client" => "qbit", "download_client_id" => "hash-a"}
      })

      listings = [{"qbit", [status("Imported.Release.2024", "hash-a")]}]

      assert ExternalTorrents.subtract_known(listings) == []
    end
  end

  describe "get/0 and put/1" do
    test "get returns an empty scan before anything is stored" do
      ExternalTorrents.put(ExternalScan.empty())

      assert %ExternalScan{needs_matching: [], external: [], scanned_at: nil} =
               ExternalTorrents.get()
    end

    test "put then get round-trips a scan" do
      torrent = %ExternalTorrent{
        id: "abc123",
        client_name: "qbit",
        client_id: "hash-a",
        title: "ubuntu-24.04.iso",
        kind: :external
      }

      scan = %ExternalScan{
        external: [torrent],
        scanned_at: DateTime.utc_now(),
        failed_clients: ["broken-client"]
      }

      :ok = ExternalTorrents.put(scan)
      loaded = ExternalTorrents.get()

      assert [%{id: "abc123"}] = loaded.external
      assert loaded.failed_clients == ["broken-client"]
    end
  end

  describe "find/1" do
    test "finds a torrent in either list of the cached scan" do
      needs = %ExternalTorrent{
        id: "needs-1",
        client_name: "qbit",
        client_id: "h1",
        title: "The.Bear.S03E02",
        kind: :needs_matching
      }

      ext = %ExternalTorrent{
        id: "ext-1",
        client_name: "qbit",
        client_id: "h2",
        title: "ubuntu.iso",
        kind: :external
      }

      :ok = ExternalTorrents.put(%ExternalScan{needs_matching: [needs], external: [ext]})

      assert %{id: "needs-1"} = ExternalTorrents.find("needs-1")
      assert %{id: "ext-1"} = ExternalTorrents.find("ext-1")
      assert ExternalTorrents.find("nope") == nil
    end
  end

  describe "scan/0" do
    test "returns an empty scan when no torrent clients are configured" do
      scan = ExternalTorrents.scan()

      assert scan.needs_matching == []
      assert scan.external == []
      assert scan.failed_clients == []
      assert %DateTime{} = scan.scanned_at
    end
  end
end
