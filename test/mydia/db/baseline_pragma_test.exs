defmodule Mydia.DB.BaselinePragmaTest do
  @moduledoc """
  Asserts the live connection actually carries the pinned settings.
  """
  use Mydia.DataCase, async: true

  @moduletag skip:
               not Mydia.DB.sqlite?() and
                 "PRAGMA assertions are SQLite-only; PostgreSQL has no equivalent"

  test "journal_mode is WAL" do
    assert pragma("journal_mode") == "wal"
  end

  test "foreign keys are enforced" do
    assert pragma("foreign_keys") == 1
  end

  test "synchronous is NORMAL" do
    assert pragma("synchronous") == 1
  end

  test "temp_store is MEMORY" do
    assert pragma("temp_store") == 2
  end

  test "cache_size matches the baseline" do
    assert pragma("cache_size") == Mydia.DB.Baseline.pinned()[:cache_size]
  end

  defp pragma(name) do
    %{rows: [[value]]} = Repo.query!("PRAGMA #{name}")
    value
  end
end
