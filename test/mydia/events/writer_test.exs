defmodule Mydia.Events.WriterTest do
  use Mydia.DataCase

  import ExUnit.CaptureLog

  alias Mydia.Events.Event
  alias Mydia.Events.Writer
  alias Phoenix.PubSub

  # Small, explicit limits so tests do not depend on the production defaults.
  # `name: nil` starts the writer unregistered, so it never collides with the
  # supervised one that Task 4 adds to the application tree.
  defp start_writer(opts) do
    pid = start_supervised!({Writer, Keyword.put(opts, :name, nil)}, id: :writer_under_test)
    Ecto.Adapters.SQL.Sandbox.allow(Mydia.Repo, self(), pid)
    pid
  end

  defp attrs(type \\ "download.initiated") do
    %{category: "downloads", type: type, metadata: %{"title" => "Test"}}
  end

  describe "enqueue/2" do
    test "flushes when the buffer reaches max_batch" do
      writer = start_writer(max_batch: 3, flush_interval_ms: 60_000)

      for _ <- 1..3, do: Writer.enqueue(attrs(), writer)

      # No explicit flush: reaching max_batch must trigger one on its own.
      # A short poll avoids racing the cast.
      assert eventually(fn -> Repo.aggregate(Event, :count) == 3 end)
    end

    test "flushes when the interval elapses below max_batch" do
      writer = start_writer(max_batch: 100, flush_interval_ms: 50)

      Writer.enqueue(attrs(), writer)

      assert eventually(fn -> Repo.aggregate(Event, :count) == 1 end)
    end

    test "logs and drops an invalid changeset without inserting" do
      writer = start_writer(max_batch: 1, flush_interval_ms: 60_000)

      log =
        capture_log(fn ->
          assert :ok = Writer.enqueue(%{category: "Invalid"}, writer)
          Writer.flush(writer)
        end)

      assert log =~ "Failed to create event asynchronously"
      assert Repo.aggregate(Event, :count) == 0
    end

    test "drops the oldest events when the buffer overflows" do
      writer = start_writer(max_batch: 100, flush_interval_ms: 60_000, max_buffer: 2)

      Writer.enqueue(attrs("download.initiated"), writer)
      Writer.enqueue(attrs("download.completed"), writer)
      Writer.enqueue(attrs("download.failed"), writer)

      log = capture_log(fn -> Writer.flush(writer) end)

      assert log =~ "buffer full"
      types = Event |> Repo.all() |> Enum.map(& &1.type) |> Enum.sort()
      assert types == ["download.completed", "download.failed"]
    end
  end

  describe "flush/1" do
    test "inserts the pending buffer and broadcasts each event" do
      writer = start_writer(max_batch: 100, flush_interval_ms: 60_000)
      PubSub.subscribe(Mydia.PubSub, "events:all")

      Writer.enqueue(attrs(), writer)
      assert Repo.aggregate(Event, :count) == 0

      assert :ok = Writer.flush(writer)

      assert Repo.aggregate(Event, :count) == 1
      assert_received {:event_created, %Event{type: "download.initiated"}}
    end

    test "logs, survives, and does not broadcast when the insert fails" do
      writer = start_writer(max_batch: 100, flush_interval_ms: 60_000)
      PubSub.subscribe(Mydia.PubSub, "events:all")

      # `metadata` is a Mydia.Settings.JsonMapType, whose dump/1 returns :error
      # for anything that is not a map, so Repo.insert_all raises
      # Ecto.ChangeError while dumping, before any SQL is sent. That matters:
      # a constraint violation would poison the surrounding sandbox transaction
      # on PostgreSQL and break every assertion after it.
      #
      # Casting the struct directly is deliberate. enqueue/2 validates through
      # the changeset, which rejects this, so it is the only way to reach the
      # rescue clause without a live database failure.
      bad = %Event{
        id: Ecto.UUID.generate(),
        category: "downloads",
        type: "download.initiated",
        severity: :info,
        metadata: "not a map",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      GenServer.cast(writer, {:event, bad})

      log = capture_log(fn -> Writer.flush(writer) end)

      assert log =~ "Events.Writer dropped 1 event(s)"
      assert Process.alive?(writer)
      assert Repo.aggregate(Event, :count) == 0
      refute_received {:event_created, _}
    end
  end

  describe "termination" do
    test "flushes the pending buffer on terminate" do
      writer = start_writer(max_batch: 100, flush_interval_ms: 60_000)

      Writer.enqueue(attrs(), writer)
      assert Repo.aggregate(Event, :count) == 0

      :ok = stop_supervised(:writer_under_test)

      assert Repo.aggregate(Event, :count) == 1
    end
  end

  # The writer inserts from its own process, so a cast is not observable the
  # instant enqueue/2 returns. Poll instead of sleeping a fixed amount.
  defp eventually(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end
end
