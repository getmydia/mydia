defmodule Mydia.Repo.Migrations.PluginKvInstanceStoreTest do
  use Mydia.DataCase, async: true

  alias Mydia.Repo

  test "plugin_kv has a covering index on (instance_id, size_bytes) for the quota aggregates" do
    {statement, params} =
      if Mydia.DB.sqlite?() do
        {"SELECT sql FROM sqlite_master WHERE type = 'index' AND name = $1", []}
      else
        {"SELECT indexdef FROM pg_indexes WHERE indexname = $1", []}
      end

    assert %{rows: [[definition]]} =
             Repo.query!(statement, ["plugin_kv_instance_size_index"] ++ params)

    assert definition =~ "instance_id"
    assert definition =~ "size_bytes"
  end
end
