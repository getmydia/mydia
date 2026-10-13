defmodule Mydia.Indexers.SearchStats.EventTest do
  use Mydia.DataCase, async: true

  alias Mydia.Indexers.SearchStats.Event
  alias Mydia.Repo

  defp ms(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  test "from_telemetry/2 builds a row with strings, milliseconds and a fresh id" do
    event =
      Event.from_telemetry(
        %{duration: ms(1_500), network: ms(1_200), result_count: 7},
        %{
          indexer_id: "def-1",
          indexer_name: "Fictional Tracker",
          indexer_type: :cardigann,
          engine: :prowlarr,
          kind: :search,
          outcome: :timeout,
          error_message: String.duplicate("x", 600)
        }
      )

    assert %Event{
             indexer_id: "def-1",
             indexer_name: "Fictional Tracker",
             indexer_type: "cardigann",
             engine: "prowlarr",
             kind: "search",
             outcome: "timeout",
             duration_ms: 1_500,
             network_ms: 1_200,
             result_count: 7
           } = event

    assert String.length(event.error_message) == 500
    assert {:ok, _} = Ecto.UUID.cast(event.id)
    assert %DateTime{} = event.inserted_at
  end

  test "from_telemetry/2 leaves engine and network nil when absent" do
    event =
      Event.from_telemetry(%{duration: ms(10)}, %{
        indexer_id: "cfg-1",
        indexer_name: "Imaginary Relay",
        indexer_type: :prowlarr,
        engine: nil,
        kind: :search,
        outcome: :ok,
        error_message: nil
      })

    assert event.engine == nil
    assert event.network_ms == nil
    assert event.result_count == 0
    assert event.error_message == nil
  end

  test "row/1 inserts through Repo.insert_all/3" do
    event =
      Event.from_telemetry(%{duration: ms(5), result_count: 1}, %{
        indexer_id: "cfg-2",
        indexer_name: "Imaginary Relay",
        indexer_type: :newznab,
        kind: :search,
        outcome: :ok
      })

    assert {1, _} = Repo.insert_all(Event, [Event.row(event)])
    assert %Event{indexer_type: "newznab"} = Repo.get!(Event, event.id)
  end
end
