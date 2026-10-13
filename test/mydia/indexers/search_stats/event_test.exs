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

  describe "error_message sanitising" do
    defp with_message(message) do
      Event.from_telemetry(%{duration: ms(1)}, %{
        indexer_id: "cfg-3",
        indexer_name: "Imaginary Relay",
        indexer_type: :newznab,
        kind: :search,
        outcome: :error,
        error_message: message
      })
    end

    test "strips NUL bytes" do
      assert with_message("bad" <> <<0>> <> "byte").error_message == "badbyte"
    end

    test "invalid UTF-8 yields a valid string" do
      message = with_message("caf" <> <<0xFF, 0xFE>> <> "e").error_message
      assert String.valid?(message)
      assert message =~ "caf"
    end

    test "non-binary values become their inspect string" do
      assert with_message({:timeout, 5}).error_message == "{:timeout, 5}"
    end

    test "length is still capped at 500" do
      assert String.length(with_message(String.duplicate("y", 900)).error_message) == 500
    end
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
