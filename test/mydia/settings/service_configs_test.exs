defmodule Mydia.Settings.ServiceConfigsTest do
  use Mydia.DataCase, async: false

  alias Mydia.Settings
  alias Mydia.Settings.IndexerConfig

  describe "resolve_env_inheritance/1" do
    # Mutates the process environment, so this file must not run concurrently
    # with other tests. Each env var is captured and restored individually to
    # keep the surrounding suite deterministic.
    setup do
      env_name = "MYDIA_TEST_NEWZNAB_ENV"

      vars = [
        "#{env_name}_BASE_URL",
        "#{env_name}_API_KEY",
        "#{env_name}_API_PATH"
      ]

      originals = Enum.map(vars, &{&1, System.get_env(&1)})
      Enum.each(vars, &System.delete_env/1)

      on_exit(fn ->
        Enum.each(originals, fn
          {var, nil} -> System.delete_env(var)
          {var, value} -> System.put_env(var, value)
        end)
      end)

      %{env_name: env_name}
    end

    test "resolves <env_name>_API_PATH into connection_settings", %{env_name: env_name} do
      System.put_env("#{env_name}_API_PATH", "custom/api")

      config = %IndexerConfig{
        name: "Test Newznab",
        type: :newznab,
        env_name: env_name,
        connection_settings: %{"timeout" => 5_000}
      }

      resolved = Settings.resolve_env_inheritance(config)

      assert resolved.connection_settings["api_path"] == "/custom/api"
      assert resolved.connection_settings["timeout"] == 5_000
    end

    test "returns connection_settings unchanged when the API path env var is unset",
         %{env_name: env_name} do
      settings = %{"timeout" => 5_000}

      config = %IndexerConfig{
        name: "Test Newznab",
        type: :newznab,
        env_name: env_name,
        connection_settings: settings
      }

      assert Settings.resolve_env_inheritance(config).connection_settings == settings
    end

    test "returns connection_settings unchanged when the API path env var is blank",
         %{env_name: env_name} do
      System.put_env("#{env_name}_API_PATH", "   ")

      settings = %{"timeout" => 5_000}

      config = %IndexerConfig{
        name: "Test Newznab",
        type: :newznab,
        env_name: env_name,
        connection_settings: settings
      }

      assert Settings.resolve_env_inheritance(config).connection_settings == settings
    end

    test "returns connection_settings unchanged when the env_name is nil" do
      settings = %{"timeout" => 5_000}

      config = %IndexerConfig{name: "Test Newznab", type: :newznab, connection_settings: settings}

      assert Settings.resolve_env_inheritance(config).connection_settings == settings
    end
  end
end
