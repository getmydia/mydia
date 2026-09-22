defmodule Mydia.Repo.SQLiteWriteContentionTest do
  @moduledoc """
  Demonstrates why the SQLite repo runs in IMMEDIATE transaction mode.

  Under WAL, a DEFERRED transaction takes a read snapshot on its first SELECT.
  If another connection commits before that transaction upgrades to a write,
  SQLite returns SQLITE_BUSY_SNAPSHOT immediately and does NOT invoke the busy
  handler, because sleeping can never resolve the conflict. That is how issue
  #283 produced "Database busy" on instances configured with a 30 second
  busy_timeout.

  IMMEDIATE mode takes the write lock at BEGIN, so contention goes through the
  busy handler and busy_timeout applies.

  That is a guarantee about how a failure arrives, not that none does. SQLite's
  busy handler polls rather than queueing, so on a loaded runner one writer can
  lose the lock to the other seven for the whole busy_timeout and surface
  "database is locked". CI hit exactly that: five or six writers failing
  together, each after the full two seconds, while a lock holder's own
  statements stalled for want of CPU. So the IMMEDIATE arm asserts that no
  failure arrives before busy_timeout has elapsed, which a DEFERRED snapshot
  conflict always does.

  This test uses its own throwaway repo rather than Mydia.Repo, because the SQL
  sandbox wraps each test in a transaction of its own.
  """
  use ExUnit.Case, async: false

  alias Mydia.MigrationTestRepo, as: TestRepo

  @writers 8
  @iterations 20
  # Deliberately short. A long timeout would make the IMMEDIATE arm take
  # minutes to fail if this test ever regresses, and the DEFERRED arm does not
  # consult the busy handler at all.
  @busy_timeout_ms 2_000

  # No adapter guard: MigrationTestRepo is always SQLite (see its moduledoc),
  # so this runs meaningfully even on a PostgreSQL suite run.

  @tag :tmp_dir
  test "DEFERRED transactions surface Database busy under concurrent writers", %{tmp_dir: tmp_dir} do
    errors = tmp_dir |> run_contention("deferred.db", :deferred) |> Enum.map(&elem(&1, 0))

    assert "Database busy" in errors,
           """
           Expected at least one SQLITE_BUSY_SNAPSHOT from concurrent deferred
           read-then-write transactions, got: #{inspect(Enum.uniq(errors))}.
           If this stopped reproducing, raise @writers or @iterations before
           concluding the mechanism is gone.
           """
  end

  @tag :tmp_dir
  test "IMMEDIATE transactions fail only after waiting out busy_timeout", %{tmp_dir: tmp_dir} do
    early =
      tmp_dir
      |> run_contention("immediate.db", :immediate)
      |> Enum.filter(fn {_message, waited_ms} -> waited_ms < @busy_timeout_ms end)

    assert early == []
  end

  defp run_contention(tmp_dir, filename, mode) do
    database = Path.join(tmp_dir, filename)
    create_counter_database!(database)

    start_supervised!(
      {TestRepo,
       database: database,
       pool_size: @writers,
       journal_mode: :wal,
       synchronous: :normal,
       busy_timeout: @busy_timeout_ms,
       default_transaction_mode: mode}
    )

    1..@writers
    |> Task.async_stream(fn _ -> writer_loop() end,
      max_concurrency: @writers,
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, errors} -> errors end)
  end

  # Built over one raw connection before the pool exists. Eight pool
  # connections opening a brand-new file at once race to switch it into WAL
  # while the table is being created, and under load that failed setup itself
  # with "database is locked" or "no such table: counter" before any
  # contention ran.
  defp create_counter_database!(database) do
    {:ok, conn} = Exqlite.Sqlite3.open(database)

    try do
      :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode = WAL")

      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          "CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)"
        )

      :ok = Exqlite.Sqlite3.execute(conn, "INSERT INTO counter (id, value) VALUES (1, 0)")
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  defp writer_loop do
    Enum.flat_map(1..@iterations, fn _ -> one_transaction() end)
  end

  # Read, yield to widen the window between snapshot and write, then write.
  # This is the shape of every Repo.transaction site in lib/mydia.
  #
  # Returns each failure's message with how long the transaction ran before
  # failing. The busy handler only gives up once its sleeps add up to
  # busy_timeout, so a lock timeout can never report less than that.
  defp one_transaction do
    started = System.monotonic_time(:millisecond)

    try do
      TestRepo.transaction(fn ->
        TestRepo.query!("SELECT value FROM counter WHERE id = 1")
        Process.sleep(1)
        TestRepo.query!("UPDATE counter SET value = value + 1 WHERE id = 1")
      end)

      []
    rescue
      error in Exqlite.Error ->
        [{error.message, System.monotonic_time(:millisecond) - started}]
    end
  end
end
