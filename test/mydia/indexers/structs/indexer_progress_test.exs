defmodule Mydia.Indexers.Structs.IndexerProgressTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Structs.IndexerProgress

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
      progress = %IndexerProgress{
        indexer: "Prowlarr",
        indexer_id: "abc-123",
        status: :ok,
        results: [:a, :b],
        result_count: 2,
        duration_ms: 812,
        completed: 1,
        total: 3
      }

      assert progress.status == :ok
      assert progress.result_count == 2
      assert progress.duration_ms == 812
    end
  end
end
