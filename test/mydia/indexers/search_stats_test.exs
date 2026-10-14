defmodule Mydia.Indexers.SearchStatsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Indexers.SearchStats
  alias Mydia.Indexers.SearchStats.{Event, Summary}
  alias Mydia.Repo

  defp insert!(attrs) do
    defaults = %{
      id: Ecto.UUID.generate(),
      indexer_id: "def-1",
      indexer_name: "Fictional Tracker",
      indexer_type: "cardigann",
      engine: "prowlarr",
      kind: "search",
      outcome: "ok",
      duration_ms: 100,
      result_count: 0,
      inserted_at: DateTime.utc_now()
    }

    Repo.insert!(struct(Event, Map.merge(defaults, attrs)))
  end

  defp ago(hours), do: DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

  describe "summary/2" do
    test "counts, rates and nearest-rank percentiles per indexer and engine" do
      for ms <- 1..10 do
        insert!(%{duration_ms: ms * 100, result_count: 4})
      end

      insert!(%{outcome: "timeout", duration_ms: 58_000})
      insert!(%{outcome: "deadline", duration_ms: 60_000})

      assert %{"def-1" => [%Summary{} = s]} = SearchStats.summary(:day)
      assert s.engine == "prowlarr"
      assert s.attempts == 12
      assert s.successes == 10
      assert s.timeouts == 2
      # 12 sorted durations: 100..1000, 58000, 60000
      assert s.p50_ms == 600
      assert s.p90_ms == 58_000
      assert s.avg_results == 4.0
      assert_in_delta Summary.success_rate(s), 10 / 12, 0.0001
    end

    test "splits one indexer by engine, busiest first" do
      insert!(%{engine: "builtin"})
      insert!(%{engine: "prowlarr"})
      insert!(%{engine: "prowlarr"})

      assert %{"def-1" => [%{engine: "prowlarr", attempts: 2}, %{engine: "builtin", attempts: 1}]} =
               SearchStats.summary(:day)
    end

    test "the window decides which rows count" do
      insert!(%{inserted_at: ago(1)})
      insert!(%{inserted_at: ago(48)})

      assert %{"def-1" => [%{attempts: 1}]} = SearchStats.summary(:day)
      assert %{"def-1" => [%{attempts: 2}]} = SearchStats.summary(:week)
    end

    test "health probes are kept apart from searches" do
      insert!(%{kind: "health", outcome: "degraded"})

      assert SearchStats.summary(:day) == %{}
      assert %{"def-1" => [%{attempts: 1, successes: 0}]} = SearchStats.summary(:day, "health")
    end

    test "avg_results is nil without a successful search" do
      insert!(%{outcome: "connection_failed"})
      assert %{"def-1" => [%{avg_results: nil}]} = SearchStats.summary(:day)
    end
  end

  test "recent_failures/2 returns newest non-ok rows for one indexer" do
    insert!(%{outcome: "ok"})
    old = insert!(%{outcome: "timeout", inserted_at: ago(3)})
    new = insert!(%{outcome: "search_failed", inserted_at: ago(1)})
    insert!(%{indexer_id: "other", outcome: "timeout"})

    assert Enum.map(SearchStats.recent_failures("def-1"), & &1.id) == [new.id, old.id]
    assert [_] = SearchStats.recent_failures("def-1", 1)
  end

  test "prune/1 deletes rows older than 14 days" do
    keep = insert!(%{inserted_at: ago(13 * 24)})
    insert!(%{inserted_at: ago(15 * 24)})

    assert SearchStats.prune() == 1
    assert [%Event{id: id}] = Repo.all(Event)
    assert id == keep.id
  end
end
