defmodule Mydia.Plugins.DeclaredSettingsTest do
  # async: false: injects the global :runtime_config application env.
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog

  alias Mydia.Config.Schema
  alias Mydia.Plugins
  alias Mydia.Plugins.DeclaredSettings
  alias Mydia.Plugins.Instances
  alias Mydia.Settings

  @slug "assistant-openai"

  @schema [
    %{"key" => "base_url", "type" => "url", "grants_host" => true, "allow_private" => true},
    %{"key" => "api_key", "type" => "secret"},
    %{"key" => "model", "type" => "string"}
  ]

  @guest_fixture Path.join([
                   __DIR__,
                   "..",
                   "..",
                   "support",
                   "fixtures",
                   "plugins",
                   "host_test_fixture.wasm"
                 ])

  defp manifest(slug) do
    %{
      "slug" => slug,
      "name" => "Assistant",
      "version" => "0.1.0",
      "capabilities" => %{"net:http" => [], "events:subscribe" => ["media_item.added"]},
      "settings_schema" => @schema
    }
  end

  defp seed(opts \\ []) do
    {:ok, config} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: "Assistant",
        version: "0.1.0",
        manifest: manifest(@slug),
        granted_capabilities: Keyword.get(opts, :granted, %{}),
        enabled: false,
        settings: Keyword.get(opts, :settings, %{})
      })

    config
  end

  defp declare(entries) do
    previous = Application.get_env(:mydia, :runtime_config)
    base = previous || Schema.defaults()

    decls =
      Enum.map(entries, fn {slug, settings} ->
        %Schema.PluginSettingsDecl{slug: slug, settings: settings}
      end)

    Application.put_env(:mydia, :runtime_config, %{base | plugin_settings: decls})

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :runtime_config)
        value -> Application.put_env(:mydia, :runtime_config, value)
      end
    end)
  end

  defp stored(key), do: Settings.get_plugin_config_by_slug(@slug).settings[key]
  defp hosts, do: Settings.get_plugin_config_by_slug(@slug).granted_capabilities["net:http"]

  test "declared settings land on the row and the default instance" do
    seed(granted: %{"net:http" => []})
    declare([{@slug, %{"base_url" => "http://ollama.lan:11434/v1", "model" => "llama3.1"}}])

    assert :ok = DeclaredSettings.sync(@slug)

    assert stored("base_url") == "http://ollama.lan:11434/v1"
    assert stored("model") == "llama3.1"
    assert Instances.default_instance(@slug).settings["model"] == "llama3.1"
  end

  test "a default instance lacking a declared key gets it though the row already matches" do
    seed(granted: %{"net:http" => []}, settings: %{"model" => "llama3.1"})
    declare([{@slug, %{"model" => "llama3.1"}}])
    {:ok, instance} = Instances.create(@slug, %{name: "Default", settings: %{}})
    assert instance.settings == %{}

    DeclaredSettings.sync(@slug)

    assert Instances.default_instance(@slug).settings["model"] == "llama3.1"
  end

  test "a declared base_url enters net:http for an approved plugin" do
    seed(granted: %{"net:http" => []})
    declare([{@slug, %{"base_url" => "http://ollama.lan:11434/v1"}}])

    DeclaredSettings.sync(@slug)

    assert "ollama.lan" in hosts()
  end

  test "an unapproved plugin stores the settings but gains no grant until approval" do
    seed(granted: %{})
    declare([{@slug, %{"base_url" => "http://ollama.lan:11434/v1"}}])

    DeclaredSettings.sync(@slug)

    assert stored("base_url") == "http://ollama.lan:11434/v1"
    assert Settings.get_plugin_config_by_slug(@slug).granted_capabilities == %{}
  end

  test "unknown keys and invalid URLs are dropped while valid keys apply" do
    seed()
    declare([{@slug, %{"base_url" => "not a url", "bogus" => "x", "model" => "m"}}])

    log = capture_log(fn -> DeclaredSettings.sync(@slug) end)

    assert stored("model") == "m"
    assert stored("base_url") == nil
    assert stored("bogus") == nil
    assert log =~ "bogus"
    assert log =~ "base_url"
  end

  test "later declarations for a slug override earlier keys" do
    seed()
    declare([{@slug, %{"model" => "a", "api_key" => "k"}}, {@slug, %{"model" => "b"}}])

    DeclaredSettings.sync_all()

    assert stored("model") == "b"
    assert stored("api_key") == "k"
  end

  test "a declared slug that is not installed is a no-op" do
    declare([{@slug, %{"model" => "m"}}])
    assert :ok = DeclaredSettings.sync(@slug)
    assert Settings.get_plugin_config_by_slug(@slug) == nil
  end

  test "an unchanged declaration writes nothing" do
    seed(settings: %{"model" => "m"})
    declare([{@slug, %{"model" => "m"}}])
    before = Settings.get_plugin_config_by_slug(@slug).updated_at

    DeclaredSettings.sync(@slug)

    assert Settings.get_plugin_config_by_slug(@slug).updated_at == before
  end

  test "keys/1 lists the declared keys that survive filtering" do
    config = seed()
    declare([{@slug, %{"model" => "m", "bogus" => "x"}}])

    assert DeclaredSettings.keys(config) == ["model"]
  end

  @tag :tmp_dir
  test "install_file/3 applies declared settings to the fresh install", %{tmp_dir: dir} do
    manifest_path = Path.join(dir, "manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest(@slug)))
    declare([{@slug, %{"model" => "llama3.1"}}])

    assert {:ok, :inactive} = Plugins.install_file(@guest_fixture, manifest_path)

    assert stored("model") == "llama3.1"
  end
end
