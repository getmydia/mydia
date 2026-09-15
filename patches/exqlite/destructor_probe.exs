# Measures whether dropping an Exqlite prepared statement stalls the VM while
# its connection is busy-waiting on another connection's write lock.
#
# Upstream Exqlite's statement destructor locks the connection mutex, which a
# busy-waiting call holds for the whole busy timeout. The destructor runs on a
# scheduler thread, so dropping the statement stalls that scheduler (and,
# through thread progress, the VM) until the busy wait gives up. With the patch
# in patches/exqlite/ nothing waits.
#
# Used two ways:
#   * The Dockerfile calls assert_patched!/0 against the NIF it just built,
#     failing the build unless the patch works.
#   * test/mydia/repo/exqlite_destructor_canary_test.exs runs measure/1 in a
#     child VM against the unpatched NIF that dev and CI use, asserting
#     upstream still stalls.

defmodule ExqliteDestructorProbe do
  alias Exqlite.Sqlite3

  @tick_ms 50

  @doc """
  Returns the longest time, in milliseconds, that an unrelated process went
  unscheduled after a statement was dropped while its connection sat in a busy
  wait of `busy_timeout_ms`.

  The stall is measured rather than the drop itself because ERTS decides when
  a dead resource's destructor runs: neither the owner's DOWN message nor a
  forced garbage collection reliably waits for it.

  Only a VM started with a single normal scheduler (`+S 1:1`) gives a
  deterministic answer. With more, the stuck scheduler may not be the one the
  measuring process runs on.
  """
  def measure(busy_timeout_ms) do
    dir = Path.join(System.tmp_dir!(), "exqlite_probe_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      path = Path.join(dir, "probe.db")
      {:ok, lock_holder} = Sqlite3.open(path)
      :ok = Sqlite3.execute(lock_holder, "PRAGMA journal_mode=WAL")
      :ok = Sqlite3.execute(lock_holder, "CREATE TABLE t (x INTEGER)")

      {:ok, waiter} = Sqlite3.open(path)
      :ok = Sqlite3.set_busy_timeout(waiter, busy_timeout_ms)

      parent = self()

      # The only reference to a statement on `waiter` lives in this process,
      # and dies with it.
      dropper = spawn(fn -> hold_statement(waiter, parent) end)

      receive do
        :prepared -> :ok
      end

      :ok = Sqlite3.execute(lock_holder, "BEGIN IMMEDIATE")
      :ok = Sqlite3.execute(lock_holder, "INSERT INTO t VALUES (0)")

      spawn(fn ->
        send(parent, {:write, Sqlite3.execute(waiter, "INSERT INTO t VALUES (1)")})
      end)

      # Let the write enter SQLite's busy handler, holding waiter's mutex.
      Process.sleep(min(200, div(busy_timeout_ms, 4)))

      ticker = spawn(fn -> tick(System.monotonic_time(:millisecond), 0) end)
      send(dropper, :drop)

      receive do
        {:write, _result} -> :ok
      end

      send(ticker, {:report, self()})

      stall_ms =
        receive do
          {:stall_ms, ms} -> ms
        end

      :ok = Sqlite3.execute(lock_holder, "COMMIT")
      :ok = Sqlite3.close(waiter)
      :ok = Sqlite3.close(lock_holder)
      stall_ms
    after
      File.rm_rf!(dir)
    end
  end

  defp hold_statement(conn, parent) do
    {:ok, statement} = Sqlite3.prepare(conn, "SELECT x FROM t")
    send(parent, :prepared)

    receive do
      :drop -> :erlang.phash2(statement)
    end
  end

  # The stall ends when the busy wait does, which is also when the report
  # request arrives, so the gap since the last tick counts too.
  defp tick(last, worst) do
    receive do
      {:report, to} ->
        now = System.monotonic_time(:millisecond)
        send(to, {:stall_ms, max(worst, now - last - @tick_ms)})
    after
      @tick_ms ->
        now = System.monotonic_time(:millisecond)
        tick(now, max(worst, now - last - @tick_ms))
    end
  end

  @doc """
  Halts the VM with a non-zero status unless the drop left the VM running.
  Run it under `elixir --erl "+S 1:1"`; see measure/1.
  """
  def assert_patched! do
    busy_timeout_ms = 2_000
    stall_ms = measure(busy_timeout_ms)

    if stall_ms < div(busy_timeout_ms, 4) do
      IO.puts("exqlite destructor probe: worst stall #{stall_ms}ms, patch in effect")
    else
      IO.puts(:stderr, """
      exqlite destructor probe FAILED: dropping a statement stalled the VM for \
      #{stall_ms}ms while its connection busy-waited (busy timeout #{busy_timeout_ms}ms).
      The built sqlite3_nif is not the patched one. Either the patch in \
      patches/exqlite/ did not apply, or Exqlite downloaded its precompiled NIF \
      instead of building from source.\
      """)

      System.halt(1)
    end
  end
end
