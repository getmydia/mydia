defmodule Mydia.Repo.TransactionModeTest do
  @moduledoc """
  Locks in the SQLite repo's transaction mode.

  Deferred transactions that read before they write get SQLITE_BUSY_SNAPSHOT
  under WAL without the busy handler ever running, which is how issue #283
  produced "Database busy" despite a 30 second busy_timeout. See
  test/mydia/repo/sqlite_write_contention_test.exs for the demonstration.
  """
  use ExUnit.Case, async: true

  test "the SQLite repo begins transactions in IMMEDIATE mode" do
    if Mydia.DB.sqlite?() do
      assert Mydia.Repo.config()[:default_transaction_mode] == :immediate
    else
      assert Mydia.DB.postgres?()
    end
  end
end
