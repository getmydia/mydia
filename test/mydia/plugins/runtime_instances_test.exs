defmodule Mydia.Plugins.RuntimeInstancesTest do
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog

  alias Mydia.Config.Schema
  alias Mydia.Plugins.AccountLinks
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.RuntimeInstances

  setup do
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :runtime_config, original),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    :ok
  end

  defp declare(decls) do
    {:ok, config} =
      Schema.defaults()
      |> Schema.changeset(%{plugin_instances: decls})
      |> Ecto.Changeset.apply_action(:insert)

    Application.put_env(:mydia, :runtime_config, config)
  end

  test "creates runtime instances with endpoint and owner credential" do
    declare([
      %{
        plugin: "plex",
        name: "Living room",
        settings: %{
          "url" => "http://192.168.1.20:32400",
          "token" => "abc",
          "sync_watched" => "on"
        }
      }
    ])

    assert :ok = RuntimeInstances.sync()

    assert [instance] = Instances.list("plex")
    assert instance.source == :runtime
    assert instance.runtime_key == "Living room"
    assert instance.enabled
    assert instance.settings == %{"url" => "http://192.168.1.20:32400", "sync_watched" => "on"}

    assert instance.approved_endpoints == [
             %{"scheme" => "http", "host" => "192.168.1.20", "port" => 32400}
           ]

    assert AccountLinks.credential(instance.id, :owner).access_token == "abc"
  end

  test "a second sync updates the same row" do
    declare([%{plugin: "plex", name: "Den", settings: %{"url" => "http://10.0.0.2:32400"}}])
    :ok = RuntimeInstances.sync()
    [first] = Instances.list("plex")

    declare([
      %{
        plugin: "plex",
        name: "Den",
        enabled: false,
        settings: %{"url" => "http://10.0.0.3:32400"}
      }
    ])

    :ok = RuntimeInstances.sync()

    assert [again] = Instances.list("plex")
    assert again.id == first.id
    refute again.enabled
    assert again.settings["url"] == "http://10.0.0.3:32400"
  end

  test "an undeclared runtime row becomes a disabled DB instance" do
    declare([%{plugin: "plex", name: "Gone", settings: %{}}])
    :ok = RuntimeInstances.sync()
    [row] = Instances.list("plex")

    declare([])

    log = capture_log(fn -> :ok = RuntimeInstances.sync() end)

    kept = Instances.get!(row.id)
    assert kept.runtime_key == nil
    assert kept.source == :db
    refute kept.enabled
    assert log =~ "Gone"
  end

  test "duplicate names for one plugin are skipped with a warning" do
    declare([
      %{plugin: "plex", name: "Twin", settings: %{}},
      %{plugin: "plex", name: "Twin", settings: %{}}
    ])

    log = capture_log(fn -> :ok = RuntimeInstances.sync() end)

    assert [_one] = Instances.list("plex")
    assert log =~ "Twin"
  end

  test "a token without a url warns" do
    declare([%{plugin: "plex", name: "Headless", settings: %{"token" => "abc"}}])

    log = capture_log(fn -> :ok = RuntimeInstances.sync() end)

    assert log =~ "declares a token but no url"
  end

  test "legacy_declarations/0 returns only translated entries" do
    declare([
      %{plugin: "plex", name: "Old", legacy_source: "media_servers", settings: %{}},
      %{plugin: "plex", name: "New", settings: %{}}
    ])

    assert [%{name: "Old"}] = RuntimeInstances.legacy_declarations()
  end
end
