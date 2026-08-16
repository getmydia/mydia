defmodule Mydia.Indexers.Structs.IndexerProgressTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.IndexerProgress

  defp search_result(title) do
    %SearchResult{
      title: title,
      download_url: "magnet:?xt=urn:btih:#{:erlang.phash2(title)}",
      indexer: "Prowlarr",
      size: 8_000_000_000,
      seeders: 100,
      leechers: 2
    }
  end

  describe "defaults" do
    test "a bare struct is a pending indexer with no results" do
      progress = %IndexerProgress{indexer: "Prowlarr", indexer_id: "abc-123", total: 3}

      assert progress.status == :pending
      assert progress.results == []
      assert progress.result_count == nil
      assert progress.error == nil
      assert progress.duration_ms == nil
      assert progress.completed == nil
    end

    test "a settled struct carries results and timing" do
      results = [search_result("Dune.2021.1080p"), search_result("Dune.2021.2160p")]

      progress = %IndexerProgress{
        indexer: "Prowlarr",
        indexer_id: "abc-123",
        status: :ok,
        results: results,
        result_count: 2,
        duration_ms: 812,
        completed: 1,
        total: 3
      }

      assert progress.status == :ok
      assert progress.results == results
      assert progress.result_count == 2
      assert progress.duration_ms == 812
    end
  end
end
