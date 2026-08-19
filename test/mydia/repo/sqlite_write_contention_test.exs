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
    errors = run_contention(tmp_dir, "deferred.db", :deferred)

    assert "Database busy" in errors,
           """
           Expected at least one SQLITE_BUSY_SNAPSHOT from concurrent deferred
           read-then-write transactions, got: #{inspect(Enum.uniq(errors))}.
           If this stopped reproducing, raise @writers or @iterations before
           concluding the mechanism is gone.
           """
  end

  @tag :tmp_dir
  test "IMMEDIATE transactions do not", %{tmp_dir: tmp_dir} do
    assert run_contention(tmp_dir, "immediate.db", :immediate) == []
  end

  defp run_contention(tmp_dir, filename, mode) do
    start_supervised!(
      {TestRepo,
       database: Path.join(tmp_dir, filename),
       pool_size: @writers,
       journal_mode: :wal,
       synchronous: :normal,
       busy_timeout: @busy_timeout_ms,
       default_transaction_mode: mode}
    )

    TestRepo.query!("CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
    TestRepo.query!("INSERT INTO counter (id, value) VALUES (1, 0)")

    1..@writers
    |> Task.async_stream(fn _ -> writer_loop() end,
      max_concurrency: @writers,
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, errors} -> errors end)
  end

  defp writer_loop do
    Enum.flat_map(1..@iterations, fn _ -> one_transaction() end)
  end

  # Read, yield to widen the window between snapshot and write, then write.
  # This is the shape of every Repo.transaction site in lib/mydia.
  defp one_transaction do
    TestRepo.transaction(fn ->
      TestRepo.query!("SELECT value FROM counter WHERE id = 1")
      Process.sleep(1)
      TestRepo.query!("UPDATE counter SET value = value + 1 WHERE id = 1")
    end)

    []
  rescue
    error in Exqlite.Error -> [error.message]
  end
end
