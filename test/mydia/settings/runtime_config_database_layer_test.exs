defmodule Mydia.Settings.RuntimeConfigDatabaseLayerTest do
  @moduledoc """
  The rescue list in load_database_config/1 is load-bearing in both directions.

  Too narrow and a fresh install fails to boot because config_settings has not
  been migrated yet. Too wide and an ordering bug becomes an empty configuration
  layer: rescuing the bare RuntimeError that Ecto raises for an unstarted Repo
  is exactly how every database-backed setting came to be dropped on every boot,
  with no log line and no failed boot to point at it.
  """
  use ExUnit.Case, async: true

  alias Mydia.Settings.RuntimeConfig

  test "an unmigrated database yields an empty layer rather than a crash" do
    assert {:ok, %{}} =
             RuntimeConfig.load_database_config(fn ->
               raise Exqlite.Error, message: "no such table: config_settings"
             end)
  end

  test "a lost connection yields an empty layer rather than a crash" do
    assert {:ok, %{}} =
             RuntimeConfig.load_database_config(fn ->
               raise DBConnection.ConnectionError, "connection not available"
             end)
  end

  test "a Postgres error yields an empty layer rather than a crash" do
    assert {:ok, %{}} =
             RuntimeConfig.load_database_config(fn ->
               raise Postgrex.Error, message: "relation config_settings does not exist"
             end)
  end

  test "a repo-not-started error is NOT swallowed into an empty layer" do
    assert_raise RuntimeError, ~r/could not lookup Ecto repo/, fn ->
      RuntimeConfig.load_database_config(fn ->
        raise "could not lookup Ecto repo Mydia.Repo because it was not started"
      end)
    end
  end
end
