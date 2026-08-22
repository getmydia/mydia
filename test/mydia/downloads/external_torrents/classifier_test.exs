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

  # Entries carry the client's adoption decision, from
  # `Mydia.Downloads.ExternalPolicy.decide/2`. `:adopt` is the default here
  # because it is what every pre-#531 caller effectively passed.
  defp entry(name, decision \\ :adopt), do: {"qbit", status(name), decision}

  defp empty_pool, do: %CandidatePool{movies: [], tv_shows: []}

  describe "classify/2 split rule" do
    test "a movie release goes to needs_matching" do
      entries = [entry("Dune.Part.Two.2024.2160p.WEB-DL.x265-GROUP")]

      {needs, external} = Classifier.classify(entries, empty_pool())

      assert [%{kind: :needs_matching, parsed: %{type: :movie}}] = needs
      assert external == []
    end

    test "a tv release goes to needs_matching" do
      entries = [entry("The.Bear.S03E02.1080p.WEB-DL.x264-GROUP")]

      {needs, external} = Classifier.classify(entries, empty_pool())

      assert [%{kind: :needs_matching, parsed: %{type: :tv_show}}] = needs
      assert external == []
    end

    test "a non-media name goes to external" do
      entries = [entry("ubuntu-24.04-desktop-amd64.iso")]

      {needs, external} = Classifier.classify(entries, empty_pool())

      assert needs == []
      assert [%{kind: :external, title: "ubuntu-24.04-desktop-amd64.iso"}] = external
    end

    test "a validator-rejected name goes to external with no parsed info" do
      entries = [entry("From.S04E05.1080p.WEB.h264-ETHEL.exe")]

      {needs, external} = Classifier.classify(entries, empty_pool())

      assert needs == []
      assert [%{kind: :external, parsed: nil, suggestions: []}] = external
    end
  end

  describe "classify/2 policy exclusion" do
    test "a movie from a client set to ignore goes to external, not needs_matching" do
      entries = [entry("Dune.Part.Two.2024.2160p.WEB-DL.x265-GROUP", :excluded_by_ignore)]

      {needs, external} = Classifier.classify(entries, empty_pool())

      assert needs == []
      assert [%{kind: :external, excluded_by_policy: true}] = external
    end

    test "a movie excluded by category also goes to external" do
      entries = [entry("Dune.Part.Two.2024.2160p.WEB-DL.x265-GROUP", :excluded_by_category)]

      {needs, external} = Classifier.classify(entries, empty_pool())

      assert needs == []
      assert [%{kind: :external, excluded_by_policy: true}] = external
    end

    test "a category-excluded torrent keeps its parsed info so a manual pull stays easy" do
      entries = [entry("Dune.Part.Two.2024.2160p.WEB-DL.x265-GROUP", :excluded_by_category)]

      {_needs, [torrent]} = Classifier.classify(entries, empty_pool())

      assert %{type: :movie} = torrent.parsed
    end

    test "an ignored torrent keeps parsed info but is not scored for suggestions" do
      # Scoring every foreign torrent every couple of minutes is work the
      # operator explicitly asked Mydia not to do.
      media_item_fixture(%{type: "tv_show", title: "The Bear"})

      entries = [entry("The.Bear.S03E02.1080p.WEB-DL.x264-GROUP", :excluded_by_ignore)]

      {_needs, [torrent]} = Classifier.classify(entries, CandidatePool.load())

      assert %{type: :tv_show} = torrent.parsed
      assert torrent.suggestions == []
    end

    test "a category-excluded torrent IS scored, since a manual pull is plausible" do
      show = media_item_fixture(%{type: "tv_show", title: "The Bear"})

      entries = [entry("The.Bear.S03E02.1080p.WEB-DL.x264-GROUP", :excluded_by_category)]

      {_needs, [torrent]} = Classifier.classify(entries, CandidatePool.load())

      assert [%{media_item_id: id} | _] = torrent.suggestions
      assert id == show.id
    end

    test "an adopted torrent is not flagged as excluded" do
      entries = [entry("Dune.Part.Two.2024.2160p.WEB-DL.x265-GROUP", :adopt)]

      {[torrent], _external} = Classifier.classify(entries, empty_pool())

      refute torrent.excluded_by_policy
    end

    test "a non-media name from an ignored client is external and flagged" do
      # It would have been :external regardless of policy, since the name does
      # not parse as media. The flag still records that policy also excluded it.
      entries = [entry("ubuntu-24.04-desktop-amd64.iso", :excluded_by_ignore)]

      {needs, external} = Classifier.classify(entries, empty_pool())

      assert needs == []
      assert [%{kind: :external, excluded_by_policy: true, suggestions: []}] = external
    end

    test "a validator-rejected name from an ignored client is external and flagged" do
      entries = [entry("From.S04E05.1080p.WEB.h264-ETHEL.exe", :excluded_by_ignore)]

      {needs, external} = Classifier.classify(entries, empty_pool())

      assert needs == []
      assert [%{kind: :external, excluded_by_policy: true, parsed: nil}] = external
    end
  end

  describe "classify/2 suggestions" do
    test "media-shaped entries are scored against the pool" do
      show = media_item_fixture(%{type: "tv_show", title: "The Bear"})
      pool = CandidatePool.load()
      entries = [entry("The.Bear.S03E02.1080p.WEB-DL.x264-GROUP")]

      {[torrent], []} = Classifier.classify(entries, pool)

      assert [%{media_item_id: id} | _] = torrent.suggestions
      assert id == show.id
    end

    test "external entries never get suggestions" do
      media_item_fixture(%{type: "tv_show", title: "Ubuntu"})
      entries = [entry("ubuntu-24.04-desktop-amd64.iso")]

      {[], [torrent]} = Classifier.classify(entries, CandidatePool.load())

      assert torrent.suggestions == []
    end
  end

  describe "classify/2 identity" do
    test "the same torrent gets the same id across two runs" do
      single = entry("ubuntu-24.04-desktop-amd64.iso")

      {[], [first]} = Classifier.classify([single], empty_pool())
      {[], [second]} = Classifier.classify([single], empty_pool())

      assert first.id == second.id
    end

    test "the same client id in two clients gets two different ids" do
      shared = status("ubuntu-24.04-desktop-amd64.iso")

      {[], torrents} =
        Classifier.classify(
          [{"qbit", shared, :adopt}, {"transmission", shared, :adopt}],
          empty_pool()
        )

      assert [a, b] = torrents
      assert a.id != b.id
    end

    test "carries the client fields and live status through" do
      entries = [{"qbit", status("ubuntu-24.04.iso", %{progress: 12.5, state: :seeding}), :adopt}]

      {[], [torrent]} = Classifier.classify(entries, empty_pool())

      assert torrent.client_name == "qbit"
      assert torrent.progress == 12.5
      assert torrent.status == :seeding
      assert torrent.save_path == "/downloads"
    end
  end
end
