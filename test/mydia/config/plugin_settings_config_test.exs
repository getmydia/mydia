defmodule Mydia.Config.PluginSettingsConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mydia.Config.Loader

  @yaml_path "test/fixtures/plugin_settings_config.yml"

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mydia.Repo, shared: true)
    saved = plugin_env()
    Enum.each(saved, fn {key, _} -> System.delete_env(key) end)
    File.rm(@yaml_path)
    erase_warnings()

    on_exit(fn ->
      Enum.each(plugin_env(), fn {key, _} -> System.delete_env(key) end)
      Enum.each(saved, fn {key, value} -> System.put_env(key, value) end)
      File.rm(@yaml_path)
      erase_warnings()
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    :ok
  end

  defp plugin_env,
    do: Enum.filter(System.get_env(), fn {k, _} -> String.starts_with?(k, "PLUGIN_") end)

  defp erase_warnings do
    for {{Loader, :warned, _} = key, _} <- :persistent_term.get(),
        do: :persistent_term.erase(key)
  end

  defp load_env, do: Loader.load(config_file: "nonexistent.yml", sources: [:env])

  test "PLUGIN_<N>_SLUG + PLUGIN_<N>_SETTINGS keep a dashed slug" do
    System.put_env("PLUGIN_0_SLUG", "assistant-openai")

    System.put_env(
      "PLUGIN_0_SETTINGS",
      ~s({"base_url":"http://ollama.lan:11434/v1","model":"llama3.1"})
    )

    assert {:ok, config} = load_env()

    assert [%{slug: "assistant-openai", settings: settings}] = config.plugin_settings
    assert settings == %{"base_url" => "http://ollama.lan:11434/v1", "model" => "llama3.1"}
  end

  test "entries are ordered by <N> numerically" do
    System.put_env("PLUGIN_10_SLUG", "b")
    System.put_env("PLUGIN_10_SETTINGS", ~s({"k":"late"}))
    System.put_env("PLUGIN_2_SLUG", "a")
    System.put_env("PLUGIN_2_SETTINGS", ~s({"k":"early"}))

    assert {:ok, config} = load_env()
    assert Enum.map(config.plugin_settings, & &1.slug) == ["a", "b"]
  end

  test "settings that are not a JSON object drop the entry with a warning" do
    System.put_env("PLUGIN_0_SLUG", "assistant-openai")
    System.put_env("PLUGIN_0_SETTINGS", ~s(["not", "an", "object"]))

    log =
      capture_log(fn ->
        assert {:ok, config} = load_env()
        assert config.plugin_settings == []
      end)

    assert log =~ "PLUGIN_0_SETTINGS"
  end

  test "a slug without settings declares nothing" do
    System.put_env("PLUGIN_0_SLUG", "assistant-openai")
    assert {:ok, config} = load_env()
    assert config.plugin_settings == []
  end

  test "removed install fields are ignored with one warning per boot" do
    System.put_env("PLUGIN_0_SLUG", "assistant-openai")
    System.put_env("PLUGIN_0_SOURCE_URL", "https://example.com/p.zip")
    System.put_env("PLUGIN_0_ENABLED", "true")

    first = capture_log(fn -> assert {:ok, _} = load_env() end)
    second = capture_log(fn -> assert {:ok, _} = load_env() end)

    assert first =~ "PLUGIN_0_ENABLED"
    assert first =~ "PLUGIN_0_SOURCE_URL"
    refute second =~ "PLUGIN_0_SOURCE_URL"
  end

  test "YAML plugin_settings load and env entries append after them" do
    File.write!(@yaml_path, """
    plugin_settings:
      - slug: assistant-openai
        settings:
          model: from-yaml
    """)

    System.put_env("PLUGIN_0_SLUG", "assistant-openai")
    System.put_env("PLUGIN_0_SETTINGS", ~s({"model":"from-env"}))

    assert {:ok, config} = Loader.load(config_file: @yaml_path, sources: [:yaml, :env])

    assert [%{settings: %{"model" => "from-yaml"}}, %{settings: %{"model" => "from-env"}}] =
             config.plugin_settings
  end

  test "YAML plugin_settings keep the exact case of setting keys" do
    File.write!(@yaml_path, """
    plugin_settings:
      - slug: assistant-openai
        settings:
          baseURL: http://x.lan/v1
    """)

    assert {:ok, config} = Loader.load(config_file: @yaml_path, sources: [:yaml])

    assert [%{settings: %{"baseURL" => "http://x.lan/v1"} = settings}] = config.plugin_settings
    assert Map.keys(settings) == ["baseURL"]
  end

  test "YAML plugin_installs is ignored with a warning" do
    File.write!(@yaml_path, """
    plugin_installs:
      - slug: webhook-notifier
        name: Webhook
    """)

    log =
      capture_log(fn ->
        assert {:ok, config} = Loader.load(config_file: @yaml_path, sources: [:yaml])
        assert config.plugin_settings == []
      end)

    assert log =~ "plugin_installs"
  end
end
