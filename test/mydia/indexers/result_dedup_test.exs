defmodule Mydia.Indexers.ResultDedupTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.{ResultDedup, SearchResult}

  @title "Glass.Harbor.2019.1080p.WEB-DL.x264-GRP"

  defp result(indexer, seeders, title \\ @title) do
    %SearchResult{
      title: title,
      size: 1_000,
      seeders: seeders,
      leechers: 0,
      download_url: "https://#{indexer}.test/#{seeders}.torrent",
      indexer: indexer
    }
  end

  test "a merged release records every tracker that returned it" do
    [merged] =
      ResultDedup.deduplicate([result("Nyaa", 5), result("TorrentDay", 40), result("EZTV", 12)])

    assert merged.indexers == ["EZTV", "Nyaa", "TorrentDay"]
  end

  test "the copy with the most seeders still wins the merge" do
    [merged] = ResultDedup.deduplicate([result("Nyaa", 5), result("TorrentDay", 40)])

    assert merged.indexer == "TorrentDay"
    assert merged.seeders == 40
    assert merged.download_url == "https://TorrentDay.test/40.torrent"
  end

  test "merging an already merged release keeps the union" do
    first = %{result("Nyaa", 5) | indexers: ["EZTV", "Nyaa"]}
    [merged] = ResultDedup.deduplicate([first, result("TorrentDay", 40)])

    assert merged.indexers == ["EZTV", "Nyaa", "TorrentDay"]
  end

  test "different releases are not merged" do
    results =
      ResultDedup.deduplicate([
        result("Nyaa", 5),
        result("TorrentDay", 40, "Glass.Harbor.2019.2160p.WEB-DL.x265-GRP")
      ])

    assert length(results) == 2
    assert Enum.all?(results, &(SearchResult.indexers(&1) == [&1.indexer]))
  end

  test "indexers/1 falls back to the result's own indexer" do
    assert SearchResult.indexers(result("Nyaa", 5)) == ["Nyaa"]
    assert SearchResult.indexers(%{result("Nyaa", 5) | indexers: ["A", "B"]}) == ["A", "B"]
  end
end
