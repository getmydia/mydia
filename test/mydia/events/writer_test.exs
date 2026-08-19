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

    test "drops newly enqueued events once the mailbox is full" do
      writer = start_writer(max_batch: 100, flush_interval_ms: 60_000, max_mailbox: 2)

      # :sys.suspend/1 halts the writer's own receive loop without touching
      # its real mailbox, so casts pile up there exactly as they would while
      # the writer is genuinely blocked inside Repo.insert_all/2.
      :sys.suspend(writer)

      Writer.enqueue(attrs("download.initiated"), writer)
      Writer.enqueue(attrs("download.completed"), writer)
      Writer.enqueue(attrs("download.failed"), writer)
      Writer.enqueue(attrs("download.paused"), writer)

      # The mailbox bound held: only the first two casts made it in, the rest
      # were shed at enqueue/2 instead of piling up further.
      assert Process.info(writer, :message_queue_len) == {:message_queue_len, 2}

      :sys.resume(writer)

      log = capture_log(fn -> Writer.flush(writer) end)

      assert log =~ "Events.Writer mailbox full, dropped 2 event(s)"
      types = Event |> Repo.all() |> Enum.map(& &1.type) |> Enum.sort()
      assert types == ["download.completed", "download.initiated"]
    end

    test "the mailbox bound is soft under concurrent enqueue/2 callers" do
      # cast_or_drop/2 reads Process.info/2 and then calls GenServer.cast/2 as
      # two separate steps. That is fine against a single caller looping,
      # since each iteration re-reads the mailbox length before casting, but
      # concurrent callers can each observe room under max_mailbox before any
      # of them casts. The result is not a hard cap: it can overshoot by up
      # to one event per caller enqueuing at the same instant. Closing that
      # gap exactly would need something like :atomics.compare_exchange/4
      # (a plain :counters get-then-add is just as racy) plus reconciling
      # that counter against buffer-overflow drops and writer restarts, and a
      # bug in that accounting either wedges every future event or silently
      # removes the bound, which is worse than a small overshoot for a
      # droppable activity log. So this test documents the real, soft
      # guarantee instead of asserting a hard cap the implementation does
      # not provide.
      #
      # caller_count is deliberately much larger than this machine's core
      # count. A small burst (say 32) can race entirely within one wave of
      # true parallelism and land every event, which would make the "some
      # events get dropped" assertion below flaky. A few hundred concurrent
      # callers cannot all be scheduled at once, so later callers reliably
      # observe an already-elevated mailbox length and get dropped, even
      # though which ones do is nondeterministic.
      caller_count = 300
      max_mailbox = 2
      writer = start_writer(max_batch: 1000, flush_interval_ms: 60_000, max_mailbox: max_mailbox)

      # :sys.suspend/1 halts the writer's own receive loop without touching
      # its real mailbox, so casts pile up there exactly as they would while
      # the writer is genuinely blocked inside Repo.insert_all/2.
      :sys.suspend(writer)

      test_pid = self()

      callers =
        for n <- 1..caller_count do
          spawn(fn ->
            send(test_pid, :ready)
            receive do: (:go -> :ok)
            Writer.enqueue(attrs("download.initiated"), writer)
            send(test_pid, {:done, n})
          end)
        end

      for _ <- callers, do: assert_receive(:ready)
      for pid <- callers, do: send(pid, :go)
      for _ <- callers, do: assert_receive({:done, _}, 5_000)

      {:message_queue_len, len} = Process.info(writer, :message_queue_len)

      # The bound still did real work: well under every offered event landed.
      assert len < caller_count
      # The bound is soft, not exact: the theoretical worst case is every
      # caller landing between the check and the cast, i.e. max_mailbox
      # plus caller_count. Actual runs land nowhere near that, but the test
      # only asserts what is actually guaranteed.
      assert len <= max_mailbox + caller_count

      :sys.resume(writer)
      Writer.flush(writer)
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

  describe "supervision" do
    test "starts after the repo and PubSub" do
      children = Mydia.Application.children()

      repo = Enum.find_index(children, &(&1 == Mydia.Repo))
      pubsub = Enum.find_index(children, &match?({Phoenix.PubSub, _}, &1))
      writer = Enum.find_index(children, &(&1 == Mydia.Events.Writer))

      assert repo, "expected a Mydia.Repo child"
      assert pubsub, "expected a Phoenix.PubSub child"
      assert writer, "expected a Mydia.Events.Writer child"

      # It inserts through the repo and broadcasts through PubSub, so both must
      # already be up when it starts, and it must stop before them on shutdown
      # so terminate/2 can still flush.
      assert repo < writer
      assert pubsub < writer
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
