defmodule Mydia.Settings.ConfigRowIsolationTest do
  use Mydia.DataCase, async: true

  alias Mydia.Settings
  alias Mydia.Settings.ConfigSetting
  alias Mydia.Repo

  # Rows are inserted straight through Repo so this exercises the read side in
  # isolation. Task 6 makes ConfigSetting.changeset/2 reject most of these, at
  # which point the only way to create one is a direct database edit, which is
  # exactly the population this read-side isolation exists for.
  defp insert_row(key, value, category \\ :server) do
    Repo.insert!(%ConfigSetting{key: key, value: value, category: category})
  end

  describe "load_database_config/0" do
    test "a good row applies" do
      insert_row("server.port", "8080")

      assert {:ok, config} = Settings.load_database_config()
      assert config.server.port == 8080
    end

    test "one uncastable row does not take the others with it" do
      insert_row("server.port", "8080")
      insert_row("server.url_host", "example.com")
      insert_row("auth.jwt_ttl_days", "not-a-number", :auth)

      assert {:ok, config} = Settings.load_database_config()

      # The good rows survived. Before this change the invalid changeset made
      # Bootstrap.run/1 drop every database-backed setting.
      assert config.server.port == 8080
      assert config.server.url_host == "example.com"
      refute Map.has_key?(config, :auth)
    end

    test "an unknown key is skipped rather than merged" do
      insert_row("server.nonexistent", "whatever")
      insert_row("server.port", "8080")

      assert {:ok, config} = Settings.load_database_config()
      assert config.server.port == 8080
      refute Map.has_key?(config.server, :nonexistent)
    end

    test "a parent and child key pair does not raise" do
      # Regression test for the boot failure. put_in_path/3 called Map.put/3 on
      # the integer already stored under :server, raising BadMapError, which
      # escaped Mydia.Config.Bootstrap.init/1 and stopped the application from
      # starting. Both rows are now rejected as unknown keys.
      insert_row("server", "4000")
      insert_row("server.port", "8080")

      assert {:ok, config} = Settings.load_database_config()
      assert config.server.port == 8080
    end

    test "a direct-lookup row contributes nothing and is not an error" do
      insert_row("crash_reporting.enabled", "true", :crash_reporting)
      insert_row("server.port", "8080")

      assert {:ok, config} = Settings.load_database_config()
      assert config.server.port == 8080
      refute Map.has_key?(config, :crash_reporting)
      assert Settings.invalid_config_settings() == []
    end
  end

  describe "invalid_config_settings/0" do
    test "reports a bad row with its key and a reason" do
      insert_row("server.port", "abc")

      assert [%{setting: setting, reason: reason}] = Settings.invalid_config_settings()
      assert setting.key == "server.port"
      assert reason =~ "server.port"
    end

    test "is empty when every row is usable" do
      insert_row("server.port", "8080")
      insert_row("feedback.enabled", "false", :feedback)

      assert Settings.invalid_config_settings() == []
    end
  end
end
