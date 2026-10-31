defmodule Mydia.Indexers.ResultDedupTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.{ResultDedup, SearchResult}
  alias Mydia.Indexers.SearchResult.Source

  @title "Glass.Harbor.2019.1080p.WEB-DL.x264-GRP"

  defp result(indexer, seeders, title \\ @title, info_url \\ nil) do
    %SearchResult{
      title: title,
      size: 1_000,
      seeders: seeders,
      leechers: 0,
      download_url: "https://#{indexer}.test/#{seeders}.torrent",
      info_url: info_url,
      indexer: indexer
    }
  end

  test "a merged release records every tracker that returned it" do
    [merged] =
      ResultDedup.deduplicate([result("Nyaa", 5), result("TorrentDay", 40), result("EZTV", 12)])

    assert SearchResult.indexers(merged) == ["EZTV", "Nyaa", "TorrentDay"]
  end

  test "a merged release keeps each tracker's own info URL" do
    [merged] =
      ResultDedup.deduplicate([
        result("Nyaa", 5, @title, "https://nyaa.example/details/1"),
        result("TorrentDay", 40, @title, "https://td.example/details/2")
      ])

    assert merged.sources == [
             %Source{indexer: "Nyaa", info_url: "https://nyaa.example/details/1"},
             %Source{indexer: "TorrentDay", info_url: "https://td.example/details/2"}
           ]
  end

  test "two copies from one tracker collapse to one source, preferring a usable URL" do
    [merged] =
      ResultDedup.deduplicate([
        result("Nyaa", 5, @title, "javascript:alert(1)"),
        result("Nyaa", 7, @title, "https://nyaa.example/details/1"),
        result("TorrentDay", 40)
      ])

    assert merged.sources == [
             %Source{indexer: "Nyaa", info_url: "https://nyaa.example/details/1"},
             %Source{indexer: "TorrentDay", info_url: nil}
           ]
  end

  test "the copy with the most seeders still wins the merge" do
    [merged] = ResultDedup.deduplicate([result("Nyaa", 5), result("TorrentDay", 40)])

    assert merged.indexer == "TorrentDay"
    assert merged.seeders == 40
    assert merged.download_url == "https://TorrentDay.test/40.torrent"
  end

  test "merging an already merged release keeps every source" do
    first = %{
      result("Nyaa", 5)
      | sources: [
          %Source{indexer: "EZTV", info_url: "https://eztv.example/details/3"},
          %Source{indexer: "Nyaa", info_url: nil}
        ]
    }

    [merged] = ResultDedup.deduplicate([first, result("TorrentDay", 40)])

    assert merged.sources == [
             %Source{indexer: "EZTV", info_url: "https://eztv.example/details/3"},
             %Source{indexer: "Nyaa", info_url: nil},
             %Source{indexer: "TorrentDay", info_url: nil}
           ]
  end

  test "different releases are not merged" do
    results =
      ResultDedup.deduplicate([
        result("Nyaa", 5),
        result("TorrentDay", 40, "Glass.Harbor.2019.2160p.WEB-DL.x265-GRP")
      ])

    assert length(results) == 2
    assert Enum.all?(results, &(&1.sources == []))
  end
end
