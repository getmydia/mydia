defmodule Mydia.Downloads.ExternalTorrents.ClassifierTest do
  use Mydia.DataCase, async: true

  alias Mydia.Downloads.ExternalTorrents.Classifier
  alias Mydia.Downloads.Structs.{CandidatePool, DownloadStatus}

  import Mydia.MediaFixtures

  defp status(name, overrides \\ %{}) do
    struct!(
      %DownloadStatus{
        id: "hash-#{System.unique_integer([:positive])}",
        name: name,
        state: :downloading,
        progress: 42.0,
        size: 1_000_000,
        save_path: "/downloads"
      },
      overrides
    )
  end

  defp empty_pool, do: %CandidatePool{movies: [], tv_shows: []}

  describe "classify/2 split rule" do
    test "a movie release goes to needs_matching" do
      entries = [{"qbit", status("Dune.Part.Two.2024.2160p.WEB-DL.x265-GROUP")}]

      {needs, external} = Classifier.classify(entries, empty_pool())

      assert [%{kind: :needs_matching, parsed: %{type: :movie}}] = needs
      assert external == []
    end

    test "a tv release goes to needs_matching" do
      entries = [{"qbit", status("The.Bear.S03E02.1080p.WEB-DL.x264-GROUP")}]

      {needs, external} = Classifier.classify(entries, empty_pool())

      assert [%{kind: :needs_matching, parsed: %{type: :tv_show}}] = needs
      assert external == []
    end

    test "a non-media name goes to external" do
      entries = [{"qbit", status("ubuntu-24.04-desktop-amd64.iso")}]

      {needs, external} = Classifier.classify(entries, empty_pool())

      assert needs == []
      assert [%{kind: :external, title: "ubuntu-24.04-desktop-amd64.iso"}] = external
    end

    test "a validator-rejected name goes to external with no parsed info" do
      entries = [{"qbit", status("From.S04E05.1080p.WEB.h264-ETHEL.exe")}]

      {needs, external} = Classifier.classify(entries, empty_pool())

      assert needs == []
      assert [%{kind: :external, parsed: nil, suggestions: []}] = external
    end
  end

  describe "classify/2 suggestions" do
    test "media-shaped entries are scored against the pool" do
      show = media_item_fixture(%{type: "tv_show", title: "The Bear"})
      pool = CandidatePool.load()
      entries = [{"qbit", status("The.Bear.S03E02.1080p.WEB-DL.x264-GROUP")}]

      {[torrent], []} = Classifier.classify(entries, pool)

      assert [%{media_item_id: id} | _] = torrent.suggestions
      assert id == show.id
    end

    test "external entries never get suggestions" do
      media_item_fixture(%{type: "tv_show", title: "Ubuntu"})
      entries = [{"qbit", status("ubuntu-24.04-desktop-amd64.iso")}]

      {[], [torrent]} = Classifier.classify(entries, CandidatePool.load())

      assert torrent.suggestions == []
    end
  end

  describe "classify/2 identity" do
    test "the same torrent gets the same id across two runs" do
      entry = {"qbit", status("ubuntu-24.04-desktop-amd64.iso")}

      {[], [first]} = Classifier.classify([entry], empty_pool())
      {[], [second]} = Classifier.classify([entry], empty_pool())

      assert first.id == second.id
    end

    test "the same client id in two clients gets two different ids" do
      shared = status("ubuntu-24.04-desktop-amd64.iso")

      {[], torrents} =
        Classifier.classify([{"qbit", shared}, {"transmission", shared}], empty_pool())

      assert [a, b] = torrents
      assert a.id != b.id
    end

    test "carries the client fields and live status through" do
      entries = [{"qbit", status("ubuntu-24.04.iso", %{progress: 12.5, state: :seeding})}]

      {[], [torrent]} = Classifier.classify(entries, empty_pool())

      assert torrent.client_name == "qbit"
      assert torrent.progress == 12.5
      assert torrent.status == :seeding
      assert torrent.save_path == "/downloads"
    end
  end
end
