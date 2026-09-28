defmodule Mydia.DB.BaselineTest do
  @moduledoc """
  Unit tests for the pinned SQLite settings.
  """
  use ExUnit.Case, async: true

  alias Mydia.DB.Baseline

  describe "apply_to/2 with the SQLite adapter" do
    test "adds every pinned setting to a bare config" do
      config = Baseline.apply_to([], Ecto.Adapters.SQLite3)

      for {key, value} <- Baseline.pinned() do
        assert Keyword.fetch(config, key) == {:ok, value},
               "expected #{key} to be #{inspect(value)}, got #{inspect(config[key])}"
      end
    end

    test "overwrites a conflicting value rather than deferring to it" do
      config = Baseline.apply_to([journal_mode: :delete], Ecto.Adapters.SQLite3)

      assert config[:journal_mode] == :wal
    end

    test "leaves per-environment settings alone" do
      config =
        Baseline.apply_to(
          [database: "/tmp/example.db", pool_size: 3, pool: Ecto.Adapters.SQL.Sandbox],
          Ecto.Adapters.SQLite3
        )

      assert config[:database] == "/tmp/example.db"
      assert config[:pool_size] == 3
      assert config[:pool] == Ecto.Adapters.SQL.Sandbox
    end
  end

  describe "apply_to/2 with the PostgreSQL adapter" do
    test "returns the config untouched" do
      config = [hostname: "localhost", pool_size: 10, timeout: 1234]

      assert Baseline.apply_to(config, Ecto.Adapters.Postgres) == config
    end
  end

  describe "pinned/0" do
    test "includes the three settings issue #283 depends on" do
      pinned = Baseline.pinned()

      assert pinned[:journal_mode] == :wal
      assert pinned[:default_transaction_mode] == :immediate
      assert pinned[:foreign_keys] == :on
    end
  end
end
