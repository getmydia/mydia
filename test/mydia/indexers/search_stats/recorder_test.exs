defmodule Mydia.Indexers.SearchStats.RecorderTest do
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Mydia.Indexers.SearchStats.{Event, Recorder, Telemetry}
  alias Mydia.Repo

  defp event(attrs \\ %{}) do
    Event.from_telemetry(
      %{duration: System.convert_time_unit(20, :millisecond, :native), result_count: 2},
      Map.merge(
        %{
          indexer_id: "def-1",
          indexer_name: "Fictional Tracker",
          indexer_type: :cardigann,
          engine: :builtin,
          kind: :search,
          outcome: :ok
        },
        attrs
      )
    )
  end

  defp start_recorder(opts) do
    pid = start_supervised!({Recorder, Keyword.merge([name: nil, attach: false], opts)})
    Sandbox.allow(Repo, self(), pid)
    pid
  end

  defp count, do: Repo.aggregate(Event, :count)

  test "record/2 inserts synchronously under the SQL sandbox" do
    assert :ok = Recorder.record(event(), :no_such_recorder)
    assert count() == 1
  end

  test "flush/1 writes buffered events as one batch" do
    pid = start_recorder([])
    Recorder.buffer(event(), pid)
    Recorder.buffer(event(), pid)
    assert count() == 0

    assert :ok = Recorder.flush(pid)
    assert count() == 2
  end

  test "reaching max_batch flushes without waiting for the timer" do
    pid = start_recorder(max_batch: 2)
    Recorder.buffer(event(), pid)
    Recorder.buffer(event(), pid)
    :sys.get_state(pid)
    assert count() == 2
  end

  test "the flush timer message writes the buffer" do
    pid = start_recorder([])
    Recorder.buffer(event(), pid)
    send(pid, :flush)
    :sys.get_state(pid)
    assert count() == 1
  end

  test "stray messages and exit signals do not crash the recorder" do
    pid = start_recorder([])
    send(pid, :unexpected)
    send(pid, {:EXIT, self(), :normal})
    :sys.get_state(pid)
    assert Process.alive?(pid)

    Recorder.buffer(event(), pid)
    assert :ok = Recorder.flush(pid)
    assert count() == 1
  end

  test "stopping the recorder flushes what is left" do
    pid = start_recorder([])
    Recorder.buffer(event(), pid)
    stop_supervised!(Recorder)
    refute Process.alive?(pid)
    assert count() == 1
  end

  test "a failed insert drops the batch with a warning and keeps running" do
    pid = start_recorder([])
    Recorder.buffer(%{event() | duration_ms: nil}, pid)

    log = capture_log(fn -> assert :ok = Recorder.flush(pid) end)

    assert log =~ "dropped 1 indexer search event"
    assert Process.alive?(pid)
    assert count() == 0
  end

  test "attach: true attaches a handler that records, and stopping detaches it" do
    pid = start_recorder(attach: true)
    handler_ids = fn -> Enum.map(:telemetry.list_handlers(Telemetry.event()), & &1.id) end

    assert {Recorder, pid} in handler_ids.()

    Recorder.handle_telemetry(
      Telemetry.event(),
      %{duration: 1_000, result_count: 0},
      %{
        indexer_id: "cfg-9",
        indexer_name: "Imaginary Relay",
        indexer_type: :prowlarr,
        kind: :search,
        outcome: :ok
      },
      %{server: pid}
    )

    assert [%Event{indexer_id: "cfg-9"}] = Repo.all(Event)

    stop_supervised!(Recorder)
    refute {Recorder, pid} in handler_ids.()
  end

  test "a malformed event is skipped without raising" do
    assert Recorder.handle_telemetry(Telemetry.event(), %{}, %{indexer_name: %{}}, %{
             server: self()
           })

    assert count() == 0
  end
end
