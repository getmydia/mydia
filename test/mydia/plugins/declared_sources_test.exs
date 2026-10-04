defmodule Mydia.Plugins.DeclaredSourcesTest do
  use Mydia.DataCase, async: false

  import Mydia.MinisignFixtures

  alias Mydia.Config.Schema.PluginSourceDecl
  alias Mydia.Plugins.DeclaredSources
  alias Mydia.Plugins.PluginSource
  alias Mydia.Plugins.Sources

  setup do
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :runtime_config, original),
        else: Application.delete_env(:mydia, :runtime_config)
    end)
  end

  defp declare(decls) do
    base = Application.get_env(:mydia, :runtime_config) || Mydia.Config.Schema.defaults()
    Application.put_env(:mydia, :runtime_config, %{base | plugin_sources: decls})
  end

  test "persists declarations as read-only rows and the declared key wins" do
    first = keypair().public
    declare([%PluginSourceDecl{url: "https://a.test/index.json", public_key: first}])
    :ok = DeclaredSources.sync()

    assert [%PluginSource{declared: true, enabled: true, public_key: ^first}] =
             Sources.list_sources()

    second = keypair().public
    declare([%PluginSourceDecl{url: "https://a.test/index.json", public_key: second}])
    :ok = DeclaredSources.sync()
    assert [%PluginSource{public_key: ^second}] = Sources.list_sources()
  end

  test "a vanished declaration leaves a disabled, removable row" do
    declare([%PluginSourceDecl{url: "https://a.test/index.json", public_key: keypair().public}])
    :ok = DeclaredSources.sync()
    declare([])
    :ok = DeclaredSources.sync()
    assert [%PluginSource{declared: false, enabled: false}] = Sources.list_sources()
  end

  test "two declarations of one URL with different keys keep the first and warn" do
    first = keypair().public

    declare([
      %PluginSourceDecl{url: "https://a.test/index.json", public_key: first},
      %PluginSourceDecl{url: "https://a.test/index.json", public_key: keypair().public}
    ])

    log = ExUnit.CaptureLog.capture_log(fn -> :ok = DeclaredSources.sync() end)

    assert log =~ "https://a.test/index.json"
    assert [%PluginSource{public_key: ^first}] = Sources.list_sources()
  end

  test "a UI-added row with the same URL becomes declared" do
    {:ok, _} =
      Sources.add_source(%{url: "https://a.test/index.json", public_key: keypair().public})

    declare([%PluginSourceDecl{url: "https://a.test/index.json", public_key: keypair().public}])
    :ok = DeclaredSources.sync()
    assert [%PluginSource{declared: true}] = Sources.list_sources()
  end
end
