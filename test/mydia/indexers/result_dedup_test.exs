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
      ResultDedup.deduplicate([
        result("Brinewater Exchange", 5),
        result("Saltmarsh Mirror", 40),
        result("Ashvale Commons", 12)
      ])

    assert SearchResult.indexers(merged) == [
             "Ashvale Commons",
             "Brinewater Exchange",
             "Saltmarsh Mirror"
           ]
  end

  test "a merged release keeps each tracker's own info URL" do
    [merged] =
      ResultDedup.deduplicate([
        result("Brinewater Exchange", 5, @title, "https://brinewater.example/details/1"),
        result("Saltmarsh Mirror", 40, @title, "https://saltmarsh.example/details/2")
      ])

    assert merged.sources == [
             %Source{
               indexer: "Brinewater Exchange",
               info_url: "https://brinewater.example/details/1"
             },
             %Source{indexer: "Saltmarsh Mirror", info_url: "https://saltmarsh.example/details/2"}
           ]
  end

  test "two copies from one tracker collapse to one source, preferring a usable URL" do
    [merged] =
      ResultDedup.deduplicate([
        result("Brinewater Exchange", 5, @title, "javascript:alert(1)"),
        result("Brinewater Exchange", 7, @title, "https://brinewater.example/details/1"),
        result("Saltmarsh Mirror", 40)
      ])

    assert merged.sources == [
             %Source{
               indexer: "Brinewater Exchange",
               info_url: "https://brinewater.example/details/1"
             },
             %Source{indexer: "Saltmarsh Mirror", info_url: nil}
           ]
  end

  test "the copy with the most seeders still wins the merge" do
    [merged] =
      ResultDedup.deduplicate([result("Brinewater Exchange", 5), result("Saltmarsh Mirror", 40)])

    assert merged.indexer == "Saltmarsh Mirror"
    assert merged.seeders == 40
    assert merged.download_url == "https://Saltmarsh Mirror.test/40.torrent"
  end

  test "merging an already merged release keeps every source" do
    first = %{
      result("Brinewater Exchange", 5)
      | sources: [
          %Source{indexer: "Ashvale Commons", info_url: "https://ashvale.example/details/3"},
          %Source{indexer: "Brinewater Exchange", info_url: nil}
        ]
    }

    [merged] = ResultDedup.deduplicate([first, result("Saltmarsh Mirror", 40)])

    assert merged.sources == [
             %Source{indexer: "Ashvale Commons", info_url: "https://ashvale.example/details/3"},
             %Source{indexer: "Brinewater Exchange", info_url: nil},
             %Source{indexer: "Saltmarsh Mirror", info_url: nil}
           ]
  end

  test "different releases are not merged" do
    results =
      ResultDedup.deduplicate([
        result("Brinewater Exchange", 5),
        result("Saltmarsh Mirror", 40, "Glass.Harbor.2019.2160p.WEB-DL.x265-GRP")
      ])

    assert length(results) == 2
    assert Enum.all?(results, &(&1.sources == []))
  end
end
