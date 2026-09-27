defmodule Mydia.RepoRuntimeConfigTest do
  use ExUnit.Case, async: false

  alias Mydia.Repo
  alias Mydia.Config.Schema

  setup do
    original_config = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original_config do
        Application.put_env(:mydia, :runtime_config, original_config)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)

    :ok
  end

  test "overlays pool_size onto repo config" do
    fake_config = %Schema{
      database: %Schema.Database{path: "custom.db", pool_size: 15}
    }

    Application.put_env(:mydia, :runtime_config, fake_config)

    {:ok, config} = Repo.init(:supervisor, pool_size: 5)
    assert config[:pool_size] == 15
  end

  test "overlays database path for SQLite when not using sandbox pool" do
    fake_config = %Schema{
      database: %Schema.Database{path: "/tmp/custom_mydia.db", pool_size: 5}
    }

    Application.put_env(:mydia, :runtime_config, fake_config)

    {:ok, config} =
      Repo.init(:supervisor, database: "default.db", pool: DBConnection.ConnectionPool)

    if Repo.__adapter__() == Ecto.Adapters.SQLite3 do
      assert config[:database] == "/tmp/custom_mydia.db"
    end
  end

  test "preserves test sandbox database path when DATABASE_PATH env is unset" do
    fake_config = %Schema{
      database: %Schema.Database{path: "mydia_dev.db", pool_size: 5}
    }

    Application.put_env(:mydia, :runtime_config, fake_config)

    {:ok, config} =
      Repo.init(:supervisor, database: "mydia_test.db", pool: Ecto.Adapters.SQL.Sandbox)

    assert config[:database] == "mydia_test.db"
  end

  test "overlays database path even under sandbox pool when DATABASE_PATH env is set" do
    orig_env = System.get_env("DATABASE_PATH")
    System.put_env("DATABASE_PATH", "/tmp/forced_mydia.db")

    on_exit(fn ->
      if orig_env do
        System.put_env("DATABASE_PATH", orig_env)
      else
        System.delete_env("DATABASE_PATH")
      end
    end)

    fake_config = %Schema{
      database: %Schema.Database{path: "/tmp/forced_mydia.db", pool_size: 5}
    }

    Application.put_env(:mydia, :runtime_config, fake_config)

    {:ok, config} =
      Repo.init(:supervisor, database: "mydia_test.db", pool: Ecto.Adapters.SQL.Sandbox)

    if Repo.__adapter__() == Ecto.Adapters.SQLite3 do
      assert config[:database] == "/tmp/forced_mydia.db"
    end
  end
end
