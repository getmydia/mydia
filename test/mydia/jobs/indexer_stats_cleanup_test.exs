defmodule Mydia.Jobs.IndexerStatsCleanupTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Indexers.SearchStats.Event
  alias Mydia.Jobs.IndexerStatsCleanup
  alias Mydia.Repo

  test "deletes rows past retention" do
    for days <- [1, 20] do
      Repo.insert!(%Event{
        id: Ecto.UUID.generate(),
        indexer_id: "def-1",
        indexer_name: "Fictional Tracker",
        indexer_type: "cardigann",
        kind: "search",
        outcome: "ok",
        duration_ms: 10,
        result_count: 0,
        inserted_at: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
      })
    end

    assert :ok = perform_job(IndexerStatsCleanup, %{})
    assert Repo.aggregate(Event, :count) == 1
  end
end
